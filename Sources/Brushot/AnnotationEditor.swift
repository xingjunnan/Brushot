import AppKit
import Carbon
import Foundation

enum AnnotationCursorKind: Equatable {
    case arrow
    case crosshair
    case openHand
    case closedHand
    case iBeam
    case resizeHorizontal
    case resizeVertical
    case resizeDiagonalDown
    case resizeDiagonalUp
    case resizeLine(Int)
}

@MainActor
enum AnnotationCursorFactory {
    private static var directionalCursors: [Int: NSCursor] = [:]

    static func cursor(for kind: AnnotationCursorKind) -> NSCursor {
        switch kind {
        case .arrow: .arrow
        case .crosshair: .crosshair
        case .openHand: .openHand
        case .closedHand: .closedHand
        case .iBeam: .iBeam
        case .resizeHorizontal: .resizeLeftRight
        case .resizeVertical: .resizeUpDown
        case .resizeDiagonalDown: directionalCursor(degrees: 135)
        case .resizeDiagonalUp: directionalCursor(degrees: 45)
        case .resizeLine(let degrees): directionalCursor(degrees: degrees)
        }
    }

    private static func directionalCursor(degrees: Int) -> NSCursor {
        let normalized = ((degrees % 180) + 180) % 180
        if let cursor = directionalCursors[normalized] { return cursor }
        let size = NSSize(width: 22, height: 22)
        let image = NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .high
            let transform = NSAffineTransform()
            transform.translateX(by: rect.midX, yBy: rect.midY)
            transform.rotate(byDegrees: CGFloat(normalized))
            transform.translateX(by: -rect.midX, yBy: -rect.midY)
            transform.concat()

            let path = NSBezierPath()
            path.move(to: NSPoint(x: 4, y: rect.midY))
            path.line(to: NSPoint(x: 18, y: rect.midY))
            path.move(to: NSPoint(x: 4, y: rect.midY))
            path.line(to: NSPoint(x: 8, y: rect.midY + 4))
            path.move(to: NSPoint(x: 4, y: rect.midY))
            path.line(to: NSPoint(x: 8, y: rect.midY - 4))
            path.move(to: NSPoint(x: 18, y: rect.midY))
            path.line(to: NSPoint(x: 14, y: rect.midY + 4))
            path.move(to: NSPoint(x: 18, y: rect.midY))
            path.line(to: NSPoint(x: 14, y: rect.midY - 4))
            path.lineCapStyle = .round
            path.lineJoinStyle = .round
            NSColor.white.setStroke()
            path.lineWidth = 4
            path.stroke()
            NSColor.black.setStroke()
            path.lineWidth = 1.6
            path.stroke()
            return true
        }
        let cursor = NSCursor(image: image, hotSpot: NSPoint(x: 11, y: 11))
        directionalCursors[normalized] = cursor
        return cursor
    }
}

@MainActor
final class AnnotationCanvasView: NSView {
    private enum Handle {
        case start
        case end
        case topLeft
        case top
        case topRight
        case left
        case right
        case bottomLeft
        case bottom
        case bottomRight
    }

    private enum Interaction {
        case creating(start: CGPoint, points: [CGPoint])
        case moving(item: AnnotationItem, start: CGPoint, originalState: AnnotationDocumentState)
        case movingStepLabel(item: AnnotationItem, start: CGPoint, originalState: AnnotationDocumentState)
        case resizing(item: AnnotationItem, handle: Handle, originalState: AnnotationDocumentState)
    }

    private enum TextEditingTarget {
        case newText
        case text(UUID)
        case initialStep(UUID)
        case step(UUID)
    }

    private enum AnnotationHitTarget {
        case item(AnnotationItem)
        case stepLabel(AnnotationItem)

        var item: AnnotationItem {
            switch self {
            case .item(let item), .stepLabel(let item): item
            }
        }
    }

    let document = AnnotationDocument()
    private(set) var baseImage: CGImage

    var onDocumentChanged: (() -> Void)?
    var onSelectionChanged: ((AnnotationItem?) -> Void)?
    var onToolShortcut: ((AnnotationTool) -> Void)?
    var onCommit: ((CaptureAction) -> Void)?
    var onCancelCapture: (() -> Void)?

    private(set) var currentTool: AnnotationTool = .select
    private var currentStyle = AnnotationStyle.defaultStyle(for: .rectangle)
    private var inlineTextStyle: AnnotationStyle?
    private var interaction: Interaction?
    private var draftItem: AnnotationItem?
    private var inlineTextView: InlineAnnotationTextView?
    private var textEditingTarget: TextEditingTarget?
    private var pendingSingleClick: DispatchWorkItem?
    private var pendingSingleClickAction: (() -> Void)?
    private var cursorTrackingArea: NSTrackingArea?
    var singleClickDelay = NSEvent.doubleClickInterval

    init(frame: CGRect, baseImage: CGImage, logicalOrigin: CGPoint = .zero) {
        self.baseImage = baseImage
        super.init(frame: frame)
        bounds = CGRect(origin: logicalOrigin, size: frame.size)
        wantsLayer = true
        layer?.masksToBounds = true
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.borderWidth = 1
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    var showsCaptureResizeHandles = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
        refreshCursor()
    }

    override func updateTrackingAreas() {
        if let cursorTrackingArea { removeTrackingArea(cursorTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeInKeyWindow, .inVisibleRect, .mouseMoved, .cursorUpdate],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        cursorTrackingArea = area
        super.updateTrackingAreas()
    }

    override func cursorUpdate(with event: NSEvent) {
        setCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func mouseMoved(with event: NSEvent) {
        setCursor(at: convert(event.locationInWindow, from: nil), modifiers: event.modifierFlags)
    }

    override func flagsChanged(with event: NSEvent) {
        let point = window.map { convert($0.mouseLocationOutsideOfEventStream, from: nil) } ?? .zero
        setCursor(at: point, modifiers: event.modifierFlags)
    }

    func setTool(_ tool: AnnotationTool, style: AnnotationStyle) {
        cancelPendingSingleClick()
        finishInlineText(commit: true)
        currentTool = tool
        currentStyle = tool == .select ? (document.selectedItem?.style ?? style) : style
        interaction = nil
        draftItem = nil
        if tool != .select {
            document.select(nil)
            onSelectionChanged?(nil)
        } else {
            onSelectionChanged?(document.selectedItem)
        }
        window?.makeFirstResponder(self)
        needsDisplay = true
        refreshCursor()
    }

    func applyStyle(_ style: AnnotationStyle) {
        if document.selectedItem == nil || document.selectedItem?.tool == currentTool {
            currentStyle = style
        }
        if let editor = inlineTextView {
            inlineTextStyle = style
            let selectedRange = editor.selectedRange()
            let fontSize = inlineEditorFontSize(style: style)
            editor.font = style.isBold
                ? .boldSystemFont(ofSize: fontSize)
                : .systemFont(ofSize: fontSize)
            editor.textColor = style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity)
            editor.typingAttributes = [
                .font: editor.font ?? NSFont.systemFont(ofSize: fontSize),
                .foregroundColor: editor.textColor ?? style.color.nsColor
            ]
            resizeInlineTextEditor(editor, preserving: selectedRange)
        }
        if var item = document.selectedItem {
            if item.tool == .sequence,
               case .badge(var step) = item.geometry,
               abs(step.badgeFrame.width - style.lineWidth) > 0.01 {
                let side = min(max(style.lineWidth, 20), 80)
                let oldBadge = step.badgeFrame.standardized
                let scale = side / max(1, oldBadge.width)
                let newBadge = clampedSquareFrame(CGRect(
                    x: step.badgeFrame.midX - side / 2,
                    y: step.badgeFrame.midY - side / 2,
                    width: side,
                    height: side
                ))
                let relativeX = step.labelFrame.minX - oldBadge.midX
                let relativeY = step.labelFrame.minY - oldBadge.midY
                step.badgeFrame = newBadge
                step.labelFrame = clampedFrame(CGRect(
                    x: newBadge.midX + relativeX * scale,
                    y: newBadge.midY + relativeY * scale,
                    width: max(28, step.labelFrame.width * scale),
                    height: max(28, step.labelFrame.height * scale)
                ))
                item.geometry = .badge(step)
                item.style = style
                document.updateContentWithoutUndo(item)
            }
            document.updateStyle(style, for: item.id)
            onDocumentChanged?()
        }
        needsDisplay = true
        refreshCursor()
    }

    func renderedImage() throws -> CGImage {
        try renderedImage(baseImage: baseImage)
    }

    func renderedImage(baseImage renderBaseImage: CGImage) throws -> CGImage {
        cancelPendingSingleClick()
        finishInlineText(commit: true)
        return try AnnotationRenderer.render(
            baseImage: renderBaseImage,
            canvasSize: bounds.size,
            items: rendererItems(document.items)
        )
    }

    func updateCaptureArea(frame: CGRect, baseImage: CGImage, logicalOrigin: CGPoint) {
        cancelPendingSingleClick()
        finishInlineText(commit: true)
        interaction = nil
        draftItem = nil
        self.baseImage = baseImage
        self.frame = frame
        bounds = CGRect(origin: logicalOrigin, size: frame.size)
        needsDisplay = true
        refreshCursor()
    }

    func deleteSelection() {
        document.deleteSelected()
        onDocumentChanged?()
        onSelectionChanged?(nil)
        needsDisplay = true
        refreshCursor()
    }

    func cancelPendingInteraction() {
        cancelPendingSingleClick()
        interaction = nil
        draftItem = nil
        needsDisplay = true
        refreshCursor()
    }

    func undo() {
        cancelPendingSingleClick()
        finishInlineText(commit: true)
        document.undo()
        onDocumentChanged?()
        onSelectionChanged?(document.selectedItem)
        needsDisplay = true
        refreshCursor()
    }

    func redo() {
        cancelPendingSingleClick()
        finishInlineText(commit: true)
        document.redo()
        onDocumentChanged?()
        onSelectionChanged?(document.selectedItem)
        needsDisplay = true
        refreshCursor()
    }

    override func mouseDown(with event: NSEvent) {
        guard inlineTextView == nil else {
            finishInlineText(commit: true)
            return
        }
        let point = clamped(convert(event.locationInWindow, from: nil))

        if event.clickCount >= 2 {
            cancelPendingSingleClick()
            if let target = hitAnnotationTarget(at: point), target.item.tool == .text {
                let item = target.item
                document.select(item.id)
                onSelectionChanged?(item)
                beginEditingText(item: item)
            } else if let target = hitAnnotationTarget(at: point), target.item.tool == .sequence {
                let item = target.item
                document.select(item.id)
                onSelectionChanged?(item)
                beginEditingStep(item: item, initialCreation: false)
            } else {
                onCommit?(.copy)
            }
            needsDisplay = true
            refreshCursor()
            return
        }

        cancelPendingSingleClick()
        let forceCreation = currentTool != .select && event.modifierFlags.contains(.option)
        if !forceCreation,
           let selected = document.selectedItem,
           let handle = hitHandle(at: point, item: selected) {
            interaction = .resizing(item: selected, handle: handle, originalState: document.state)
            setCursorKind(cursorKind(for: handle, item: selected))
            return
        }

        if !forceCreation, let target = hitAnnotationTarget(at: point) {
            let item = target.item
            document.select(item.id)
            onSelectionChanged?(item)
            switch target {
            case .stepLabel:
                interaction = .movingStepLabel(item: item, start: point, originalState: document.state)
            case .item:
                interaction = .moving(item: item, start: point, originalState: document.state)
            }
            setCursorKind(.closedHand)
            needsDisplay = true
            return
        }

        document.select(nil)
        onSelectionChanged?(nil)
        if currentTool == .select {
            needsDisplay = true
            return
        }

        switch currentTool {
        case .text:
            scheduleSingleClick { [weak self] in self?.beginNewText(at: point) }
        case .sequence:
            scheduleSingleClick { [weak self] in self?.addSequence(at: point) }
        case .pen, .mosaic:
            interaction = .creating(start: point, points: [point])
            draftItem = AnnotationItem(tool: currentTool, geometry: .path([point]), style: currentStyle)
            needsDisplay = true
        case .rectangle, .ellipse, .highlight:
            interaction = .creating(start: point, points: [point])
            draftItem = AnnotationItem(tool: currentTool, geometry: .rect(CGRect(origin: point, size: .zero)), style: currentStyle)
            needsDisplay = true
        case .line, .arrow:
            interaction = .creating(start: point, points: [point])
            draftItem = AnnotationItem(tool: currentTool, geometry: .line(start: point, end: point), style: currentStyle)
            needsDisplay = true
        case .select:
            break
        }
        refreshCursor(at: point, modifiers: event.modifierFlags)
    }

    override func mouseDragged(with event: NSEvent) {
        cancelPendingSingleClick()
        let point = clamped(convert(event.locationInWindow, from: nil))
        guard let interaction else { return }

        switch interaction {
        case .creating(let start, var points):
            switch currentTool {
            case .pen, .mosaic:
                if let last = points.last, distance(last, point) >= 1.5 {
                    points.append(point)
                }
                self.interaction = .creating(start: start, points: points)
                draftItem?.geometry = .path(points)
            case .rectangle, .ellipse, .highlight:
                draftItem?.geometry = .rect(rect(from: start, to: point))
            case .line, .arrow:
                draftItem?.geometry = .line(start: start, end: constrainedLineEnd(point, start: start, event: event))
            default:
                break
            }
        case .moving(let original, let start, _):
            let rawOffset = CGPoint(x: point.x - start.x, y: point.y - start.y)
            var item = original
            item.geometry = original.geometry.translated(by: clampedOffset(rawOffset, for: original.bounds))
            document.updateLive(item)
            onSelectionChanged?(item)
            setCursorKind(.closedHand)
        case .movingStepLabel(let original, let start, _):
            let rawOffset = CGPoint(x: point.x - start.x, y: point.y - start.y)
            var item = original
            if case .badge(var step) = original.geometry {
                step.labelFrame = clampedFrame(step.labelFrame.offsetBy(dx: rawOffset.x, dy: rawOffset.y))
                item.geometry = .badge(step)
                document.updateLive(item)
                onSelectionChanged?(item)
            }
            setCursorKind(.closedHand)
        case .resizing(let original, let handle, _):
            var item = original
            item.geometry = resizedGeometry(of: original, handle: handle, point: point)
            if original.tool == .text {
                let originalHeight = max(1, original.geometry.bounds.height)
                let scale = item.geometry.bounds.height / originalHeight
                item.style.fontSize = min(144, max(8, original.style.fontSize * scale))
            } else if original.tool == .sequence,
                      case .badge(let step) = item.geometry {
                item.style.lineWidth = min(max(step.badgeFrame.width, 20), 80)
            }
            document.updateLive(item)
            onSelectionChanged?(item)
            setCursorKind(cursorKind(for: handle, item: item))
        }
        onDocumentChanged?()
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let interaction else { return }
        defer {
            self.interaction = nil
            draftItem = nil
            needsDisplay = true
            refreshCursor(at: clamped(convert(event.locationInWindow, from: nil)), modifiers: event.modifierFlags)
        }

        switch interaction {
        case .creating:
            guard let draftItem, isMeaningful(draftItem) else { return }
            let item = document.add(tool: draftItem.tool, geometry: draftItem.geometry, style: draftItem.style)
            onSelectionChanged?(item)
            onDocumentChanged?()
        case .moving(_, _, let originalState):
            document.commitLiveChange(from: originalState, actionName: L.text("移动标注"))
            onDocumentChanged?()
        case .movingStepLabel(_, _, let originalState):
            document.commitLiveChange(from: originalState, actionName: L.text("移动步骤文字"))
            onDocumentChanged?()
        case .resizing(let original, _, let originalState):
            document.commitLiveChange(
                from: originalState,
                actionName: L.text("缩放标注"),
                includesFontSize: original.tool == .text,
                includesLineWidth: original.tool == .sequence
            )
            onDocumentChanged?()
        }
    }

    override func keyDown(with event: NSEvent) {
        cancelPendingSingleClick()
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let characters = event.charactersIgnoringModifiers?.lowercased() ?? ""

        if modifiers.contains(.command), characters == "z" {
            modifiers.contains(.shift) ? redo() : undo()
            return
        }
        if modifiers.contains(.command), characters == "c" {
            onCommit?(.copy)
            return
        }
        if modifiers.contains(.command), characters == "s" {
            onCommit?(.saveToDownloads)
            return
        }
        if event.keyCode == UInt16(kVK_Delete) || event.keyCode == UInt16(kVK_ForwardDelete) {
            deleteSelection()
            return
        }
        if event.keyCode == UInt16(kVK_Escape) {
            if inlineTextView != nil {
                finishInlineText(commit: false)
            } else if interaction != nil || draftItem != nil {
                interaction = nil
                draftItem = nil
                needsDisplay = true
            } else if document.selectedID != nil {
                document.select(nil)
                onSelectionChanged?(nil)
                needsDisplay = true
            } else {
                onCancelCapture?()
            }
            return
        }
        if modifiers.isDisjoint(with: [.command, .control, .option]),
           let key = characters.first,
           let tool = AnnotationTool.allCases.first(where: { $0.shortcut == key }) {
            onToolShortcut?(tool)
            return
        }
        // Do not forward unknown keys to SelectionOverlayView. The overlay owns
        // this canvas and forwarding would route the same event back here.
        return
    }

    override func draw(_ dirtyRect: NSRect) {
        let visibleItems = draftItem.map { document.items + [$0] } ?? document.items
        if let image = try? AnnotationRenderer.render(
            baseImage: baseImage,
            canvasSize: bounds.size,
            items: rendererItems(itemsForDisplay(visibleItems))
        ) {
            NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
        } else {
            NSImage(cgImage: baseImage, size: bounds.size).draw(in: bounds)
        }

        if inlineTextView == nil, let selected = document.selectedItem {
            drawSelection(for: selected)
        }
        if showsCaptureResizeHandles {
            drawCaptureResizeHandles()
        }
    }

    func itemsForDisplay(_ items: [AnnotationItem]) -> [AnnotationItem] {
        guard let textEditingTarget else { return items }
        switch textEditingTarget {
        case .newText:
            return items
        case .text(let editingID):
            return items.filter { $0.id != editingID }
        case .initialStep(let editingID), .step(let editingID):
            return items.map { item in
                guard item.id == editingID, case .badge(var step) = item.geometry else { return item }
                var displayItem = item
                step.text = ""
                displayItem.geometry = .badge(step)
                return displayItem
            }
        }
    }

    private func rendererItems(_ items: [AnnotationItem]) -> [AnnotationItem] {
        let offset = CGPoint(x: -bounds.minX, y: -bounds.minY)
        return items.map { item in
            var translated = item
            translated.geometry = item.geometry.translated(by: offset)
            return translated
        }
    }

    private func drawCaptureResizeHandles() {
        let rect = bounds.insetBy(dx: 3, dy: 3)
        let points = [
            CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.minY),
            CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.minX, y: rect.midY),
            CGPoint(x: rect.maxX, y: rect.midY), CGPoint(x: rect.minX, y: rect.maxY),
            CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.maxY)
        ]
        for point in points {
            let handle = CGRect(x: point.x - 3, y: point.y - 3, width: 6, height: 6)
            NSColor.white.setFill()
            NSBezierPath(rect: handle).fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(rect: handle).stroke()
        }
    }

    private func scheduleSingleClick(_ action: @escaping () -> Void) {
        cancelPendingSingleClick()
        let workItem = DispatchWorkItem { [weak self] in
            self?.runPendingSingleClick()
        }
        pendingSingleClickAction = action
        pendingSingleClick = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + singleClickDelay, execute: workItem)
    }

    private func cancelPendingSingleClick() {
        pendingSingleClick?.cancel()
        pendingSingleClick = nil
        pendingSingleClickAction = nil
    }

    private func runPendingSingleClick() {
        let action = pendingSingleClickAction
        pendingSingleClick = nil
        pendingSingleClickAction = nil
        action?()
    }

    func performPendingSingleClickNow() {
        guard let action = pendingSingleClickAction else { return }
        cancelPendingSingleClick()
        action()
    }

    private func addSequence(at point: CGPoint) {
        let diameter = min(max(currentStyle.lineWidth, 20), 80)
        let badgeFrame = clampedSquareFrame(CGRect(
            x: point.x - diameter / 2,
            y: point.y - diameter / 2,
            width: diameter,
            height: diameter
        ))
        let labelFrame = initialStepLabelFrame(for: badgeFrame)
        let item = document.add(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: badgeFrame,
                number: 0,
                labelFrame: labelFrame,
                text: ""
            )),
            style: currentStyle
        )
        onSelectionChanged?(item)
        onDocumentChanged?()
        needsDisplay = true
        beginEditingStep(item: item, initialCreation: true)
    }

    private func beginNewText(at point: CGPoint) {
        let width = min(max(currentStyle.fontSize + 14, 28), max(28, bounds.maxX - point.x))
        let height = min(max(currentStyle.fontSize + 12, 28), max(28, bounds.maxY - point.y))
        beginTextEditor(
            frame: CGRect(x: point.x, y: point.y, width: width, height: height),
            value: "",
            target: .newText,
            style: currentStyle
        )
    }

    private func beginEditingText(item: AnnotationItem) {
        guard case .text(let frame, let value) = item.geometry else { return }
        beginTextEditor(frame: frame, value: value, target: .text(item.id), style: item.style)
    }

    private func beginEditingStep(item: AnnotationItem, initialCreation: Bool) {
        guard case .badge(let step) = item.geometry else { return }
        beginTextEditor(
            frame: step.labelFrame,
            value: step.text,
            target: initialCreation ? .initialStep(item.id) : .step(item.id),
            style: item.style
        )
    }

    private func beginTextEditor(
        frame: CGRect,
        value: String,
        target: TextEditingTarget,
        style: AnnotationStyle
    ) {
        finishInlineText(commit: true)
        let editor = InlineAnnotationTextView(frame: clampedFrame(frame))
        editor.string = value
        let fontSize = editorFontSize(style: style, target: target)
        editor.font = style.isBold
            ? .boldSystemFont(ofSize: fontSize)
            : .systemFont(ofSize: fontSize)
        editor.textColor = style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity)
        editor.drawsBackground = false
        editor.backgroundColor = .clear
        editor.onFinish = { [weak self, weak editor] commit in
            guard let self, let editor else { return }
            self.finishInlineText(editor: editor, commit: commit)
        }
        editor.onTextChanged = { [weak self, weak editor] in
            guard let self, let editor else { return }
            self.resizeInlineTextEditor(editor)
        }
        addSubview(editor)
        inlineTextView = editor
        inlineTextStyle = style
        textEditingTarget = target
        let endRange = NSRange(location: editor.string.utf16.count, length: 0)
        resizeInlineTextEditor(editor, preserving: endRange)
        window?.makeFirstResponder(editor)
        editor.setSelectedRange(endRange)
        editor.scrollRangeToVisible(endRange)
        setCursorKind(.iBeam)
    }

    private func resizeInlineTextEditor(
        _ editor: InlineAnnotationTextView,
        preserving selection: NSRange? = nil
    ) {
        let selectedRange = selection ?? editor.selectedRange()
        let font = editor.font ?? NSFont.systemFont(ofSize: currentStyle.fontSize)
        let value = editor.string.isEmpty ? " " : editor.string
        let oldMaxX = editor.frame.maxX
        let expandsToLeft = stepEditorExpandsToLeft(editor)
        let maxWidth = max(
            28,
            expandsToLeft ? oldMaxX - bounds.minX : bounds.maxX - editor.frame.minX
        )
        let maxHeight = max(28, bounds.maxY - editor.frame.minY)
        let horizontalPadding = editor.textContainerInset.width * 2 + 10
        let verticalPadding = editor.textContainerInset.height * 2 + 4
        let measurement = NSAttributedString(
            string: value,
            attributes: [
                .font: font,
                .paragraphStyle: NSParagraphStyle.default
            ]
        ).boundingRect(
            with: CGSize(width: max(16, maxWidth - horizontalPadding), height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading, .usesDeviceMetrics]
        )
        let width = min(maxWidth, max(28, ceil(measurement.width) + horizontalPadding))
        let height = min(maxHeight, max(font.ascender - font.descender + verticalPadding, ceil(measurement.height) + verticalPadding))
        editor.setFrameSize(CGSize(width: width, height: height))
        if expandsToLeft {
            editor.setFrameOrigin(CGPoint(x: max(bounds.minX, oldMaxX - width), y: editor.frame.minY))
        }
        editor.prepareTextContainerForCurrentSize()
        if let layoutManager = editor.layoutManager, let textContainer = editor.textContainer {
            layoutManager.ensureLayout(for: textContainer)
        }
        let safeLocation = min(selectedRange.location, editor.string.utf16.count)
        let safeLength = min(selectedRange.length, editor.string.utf16.count - safeLocation)
        let restoredRange = NSRange(location: safeLocation, length: safeLength)
        editor.setSelectedRange(restoredRange)
        editor.scrollRangeToVisible(restoredRange)
    }

    private func finishInlineText(commit: Bool) {
        guard let editor = inlineTextView else { return }
        finishInlineText(editor: editor, commit: commit)
    }

    private func finishInlineText(editor: InlineAnnotationTextView, commit: Bool) {
        guard inlineTextView === editor else { return }
        let value = editor.string
        let isEmpty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let target = textEditingTarget
        let frame = editor.frame
        let style = inlineTextStyle ?? currentStyle
        inlineTextView = nil
        inlineTextStyle = nil
        textEditingTarget = nil
        editor.onFinish = nil
        editor.removeFromSuperview()

        guard commit, let target else {
            window?.makeFirstResponder(self)
            refreshCursor()
            return
        }

        switch target {
        case .newText:
            guard !isEmpty else { break }
            let item = document.add(tool: .text, geometry: .text(frame: frame, value: value), style: style)
            onSelectionChanged?(item)
        case .text(let itemID):
            guard !isEmpty, var item = document.items.first(where: { $0.id == itemID }) else { break }
            item.geometry = .text(frame: frame, value: value)
            document.updateStyle(style, for: itemID)
            document.updateContent(item, actionName: L.text("编辑文字"))
            document.select(item.id)
            onSelectionChanged?(document.selectedItem)
        case .initialStep(let itemID), .step(let itemID):
            guard var item = document.items.first(where: { $0.id == itemID }),
                  case .badge(var step) = item.geometry else { break }
            step.labelFrame = frame
            step.text = isEmpty ? "" : value
            item.geometry = .badge(step)
            item.style = style
            document.updateStyle(style, for: itemID)
            if case .initialStep = target {
                document.updateContentWithoutUndo(item)
            } else {
                document.updateContent(item, actionName: L.text("编辑步骤文字"))
            }
            document.select(item.id)
            onSelectionChanged?(document.selectedItem)
        }
        onDocumentChanged?()
        window?.makeFirstResponder(self)
        needsDisplay = true
        refreshCursor()
    }

    private func initialStepLabelFrame(for badgeFrame: CGRect) -> CGRect {
        let gap: CGFloat = 7
        let preferredWidth: CGFloat = 160
        let minimumWidth: CGFloat = 42
        let fontSize = max(10, badgeFrame.width * 0.52)
        let height = max(28, ceil(fontSize * 1.45))
        let rightSpace = bounds.maxX - badgeFrame.maxX - gap
        let leftSpace = badgeFrame.minX - bounds.minX - gap
        let useRight = rightSpace >= minimumWidth || rightSpace >= leftSpace
        let available = max(minimumWidth, useRight ? rightSpace : leftSpace)
        let width = min(preferredWidth, available)
        let x = useRight ? badgeFrame.maxX + gap : badgeFrame.minX - gap - width
        return clampedFrame(CGRect(
            x: x,
            y: badgeFrame.midY - height / 2,
            width: width,
            height: height
        ))
    }

    private func editorFontSize(style: AnnotationStyle, target: TextEditingTarget) -> CGFloat {
        switch target {
        case .initialStep, .step:
            return max(10, style.lineWidth * 0.52)
        case .newText, .text:
            return style.fontSize
        }
    }

    private func inlineEditorFontSize(style: AnnotationStyle) -> CGFloat {
        guard let textEditingTarget else { return style.fontSize }
        return editorFontSize(style: style, target: textEditingTarget)
    }

    private func stepEditorExpandsToLeft(_ editor: InlineAnnotationTextView) -> Bool {
        guard let textEditingTarget else { return false }
        let itemID: UUID
        switch textEditingTarget {
        case .initialStep(let id), .step(let id): itemID = id
        case .newText, .text: return false
        }
        guard let item = document.items.first(where: { $0.id == itemID }),
              case .badge(let step) = item.geometry else { return false }
        return editor.frame.midX < step.badgeFrame.midX
    }

    private func hitAnnotationTarget(at point: CGPoint) -> AnnotationHitTarget? {
        for item in document.items.reversed() {
            if case .badge(let step) = item.geometry,
               !step.text.isEmpty,
               step.labelFrame.standardized.insetBy(dx: -4, dy: -4).contains(point) {
                return .stepLabel(item)
            }
            if AnnotationHitTesting.contains(point, item: item) {
                return .item(item)
            }
        }
        return nil
    }

    private func hitHandle(at point: CGPoint, item: AnnotationItem) -> Handle? {
        for (handle, handlePoint) in handles(for: item) where distance(point, handlePoint) <= 8 {
            return handle
        }
        return nil
    }

    private func handles(for item: AnnotationItem) -> [(Handle, CGPoint)] {
        if case .line(let start, let end) = item.geometry {
            return [(.start, start), (.end, end)]
        }
        let rect: CGRect
        if case .badge(let step) = item.geometry {
            rect = step.badgeFrame.standardized
        } else {
            rect = item.geometry.bounds.standardized
        }
        return [
            (.topLeft, CGPoint(x: rect.minX, y: rect.minY)),
            (.top, CGPoint(x: rect.midX, y: rect.minY)),
            (.topRight, CGPoint(x: rect.maxX, y: rect.minY)),
            (.left, CGPoint(x: rect.minX, y: rect.midY)),
            (.right, CGPoint(x: rect.maxX, y: rect.midY)),
            (.bottomLeft, CGPoint(x: rect.minX, y: rect.maxY)),
            (.bottom, CGPoint(x: rect.midX, y: rect.maxY)),
            (.bottomRight, CGPoint(x: rect.maxX, y: rect.maxY))
        ]
    }

    private func drawSelection(for item: AnnotationItem) {
        NSColor.systemBlue.setStroke()
        if case .badge(let step) = item.geometry {
            let badgeOutline = NSBezierPath(ovalIn: step.badgeFrame.standardized.insetBy(dx: -3, dy: -3))
            badgeOutline.lineWidth = 1
            badgeOutline.setLineDash([4, 3], count: 2, phase: 0)
            badgeOutline.stroke()
            if !step.text.isEmpty {
                let labelOutline = NSBezierPath(rect: step.labelFrame.standardized.insetBy(dx: -2, dy: -2))
                labelOutline.lineWidth = 1
                labelOutline.setLineDash([3, 3], count: 2, phase: 0)
                labelOutline.stroke()
            }
        } else {
            let rect = item.geometry.bounds.standardized.insetBy(dx: -3, dy: -3)
            let outline = NSBezierPath(rect: rect)
            outline.lineWidth = 1
            outline.setLineDash([4, 3], count: 2, phase: 0)
            outline.stroke()
        }

        for (_, point) in handles(for: item) {
            let handleRect = CGRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)
            NSColor.white.setFill()
            NSBezierPath(rect: handleRect).fill()
            NSColor.systemBlue.setStroke()
            NSBezierPath(rect: handleRect).stroke()
        }
    }

    private func resizedGeometry(of item: AnnotationItem, handle: Handle, point: CGPoint) -> AnnotationGeometry {
        if case .line(let start, let end) = item.geometry {
            switch handle {
            case .start: return .line(start: point, end: end)
            case .end: return .line(start: start, end: point)
            default: return item.geometry
            }
        }

        let source = item.geometry.bounds.standardized
        let minimum: CGFloat = 8
        if item.tool == .sequence, case .badge(var step) = item.geometry {
            let badgeSource = step.badgeFrame.standardized
            let badgeDestination = clampedSquareFrame(
                squareFrame(from: badgeSource, handle: handle, point: point, minimum: 20)
            )
            let scale = badgeDestination.width / max(1, badgeSource.width)
            let relativeX = step.labelFrame.minX - badgeSource.midX
            let relativeY = step.labelFrame.minY - badgeSource.midY
            step.badgeFrame = badgeDestination
            step.labelFrame = clampedFrame(CGRect(
                x: badgeDestination.midX + relativeX * scale,
                y: badgeDestination.midY + relativeY * scale,
                width: max(28, step.labelFrame.width * scale),
                height: max(28, step.labelFrame.height * scale)
            ))
            return .badge(step)
        }
        var destination = source
        switch handle {
        case .topLeft:
            destination = CGRect(x: min(point.x, source.maxX - minimum), y: min(point.y, source.maxY - minimum), width: max(minimum, source.maxX - point.x), height: max(minimum, source.maxY - point.y))
        case .top:
            destination = CGRect(x: source.minX, y: min(point.y, source.maxY - minimum), width: source.width, height: max(minimum, source.maxY - point.y))
        case .topRight:
            destination = CGRect(x: source.minX, y: min(point.y, source.maxY - minimum), width: max(minimum, point.x - source.minX), height: max(minimum, source.maxY - point.y))
        case .left:
            destination = CGRect(x: min(point.x, source.maxX - minimum), y: source.minY, width: max(minimum, source.maxX - point.x), height: source.height)
        case .right:
            destination = CGRect(x: source.minX, y: source.minY, width: max(minimum, point.x - source.minX), height: source.height)
        case .bottomLeft:
            destination = CGRect(x: min(point.x, source.maxX - minimum), y: source.minY, width: max(minimum, source.maxX - point.x), height: max(minimum, point.y - source.minY))
        case .bottom:
            destination = CGRect(x: source.minX, y: source.minY, width: source.width, height: max(minimum, point.y - source.minY))
        case .bottomRight:
            destination = CGRect(x: source.minX, y: source.minY, width: max(minimum, point.x - source.minX), height: max(minimum, point.y - source.minY))
        default:
            return item.geometry
        }
        destination = clampedFrame(destination)
        return item.geometry.scaled(from: source, to: destination)
    }

    private func squareFrame(
        from source: CGRect,
        handle: Handle,
        point: CGPoint,
        minimum: CGFloat
    ) -> CGRect {
        let side: CGFloat
        switch handle {
        case .topLeft:
            side = max(minimum, min(source.maxX - point.x, source.maxY - point.y))
            return CGRect(x: source.maxX - side, y: source.maxY - side, width: side, height: side)
        case .top:
            side = max(minimum, source.maxY - point.y)
            return CGRect(x: source.midX - side / 2, y: source.maxY - side, width: side, height: side)
        case .topRight:
            side = max(minimum, min(point.x - source.minX, source.maxY - point.y))
            return CGRect(x: source.minX, y: source.maxY - side, width: side, height: side)
        case .left:
            side = max(minimum, source.maxX - point.x)
            return CGRect(x: source.maxX - side, y: source.midY - side / 2, width: side, height: side)
        case .right:
            side = max(minimum, point.x - source.minX)
            return CGRect(x: source.minX, y: source.midY - side / 2, width: side, height: side)
        case .bottomLeft:
            side = max(minimum, min(source.maxX - point.x, point.y - source.minY))
            return CGRect(x: source.maxX - side, y: source.minY, width: side, height: side)
        case .bottom:
            side = max(minimum, point.y - source.minY)
            return CGRect(x: source.midX - side / 2, y: source.minY, width: side, height: side)
        case .bottomRight:
            side = max(minimum, min(point.x - source.minX, point.y - source.minY))
            return CGRect(x: source.minX, y: source.minY, width: side, height: side)
        case .start, .end:
            return source
        }
    }

    private func clampedOffset(_ offset: CGPoint, for itemBounds: CGRect) -> CGPoint {
        CGPoint(
            x: min(max(offset.x, bounds.minX - itemBounds.minX), bounds.maxX - itemBounds.maxX),
            y: min(max(offset.y, bounds.minY - itemBounds.minY), bounds.maxY - itemBounds.maxY)
        )
    }

    private func clamped(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }

    private func clampedFrame(_ frame: CGRect) -> CGRect {
        let standardized = frame.standardized
        let width = min(max(standardized.width, 8), bounds.width)
        let height = min(max(standardized.height, 8), bounds.height)
        return CGRect(
            x: min(max(standardized.minX, bounds.minX), bounds.maxX - width),
            y: min(max(standardized.minY, bounds.minY), bounds.maxY - height),
            width: width,
            height: height
        )
    }

    private func clampedSquareFrame(_ frame: CGRect) -> CGRect {
        let standardized = frame.standardized
        let side = min(max(standardized.width, 8), bounds.width, bounds.height)
        return CGRect(
            x: min(max(standardized.minX, bounds.minX), bounds.maxX - side),
            y: min(max(standardized.minY, bounds.minY), bounds.maxY - side),
            width: side,
            height: side
        )
    }

    private func rect(from start: CGPoint, to end: CGPoint) -> CGRect {
        CGRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
    }

    private func constrainedLineEnd(_ point: CGPoint, start: CGPoint, event: NSEvent) -> CGPoint {
        guard event.modifierFlags.contains(.shift) else { return point }
        let dx = point.x - start.x
        let dy = point.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return point }
        let step = CGFloat.pi / 4
        let angle = (atan2(dy, dx) / step).rounded() * step
        return clamped(CGPoint(x: start.x + cos(angle) * length, y: start.y + sin(angle) * length))
    }

    private func isMeaningful(_ item: AnnotationItem) -> Bool {
        switch item.geometry {
        case .path(let points):
            return points.count > 1 && item.geometry.bounds.width + item.geometry.bounds.height >= 2
        case .line(let start, let end):
            return distance(start, end) >= 3
        default:
            return item.geometry.bounds.width >= 3 && item.geometry.bounds.height >= 3
        }
    }

    private func distance(_ first: CGPoint, _ second: CGPoint) -> CGFloat {
        hypot(first.x - second.x, first.y - second.y)
    }

    func resolvedCursorKind(
        at point: CGPoint,
        modifierFlags: NSEvent.ModifierFlags = []
    ) -> AnnotationCursorKind {
        if inlineTextView != nil { return .iBeam }
        if currentTool != .select, modifierFlags.contains(.option) { return .crosshair }

        if let interaction {
            switch interaction {
            case .creating:
                return .crosshair
            case .moving, .movingStepLabel:
                return .closedHand
            case .resizing(let item, let handle, _):
                return cursorKind(for: handle, item: item)
            }
        }

        if let selected = document.selectedItem,
           let handle = hitHandle(at: point, item: selected) {
            return cursorKind(for: handle, item: selected)
        }
        if hitAnnotationTarget(at: point) != nil { return .openHand }
        return currentTool == .select ? .arrow : .crosshair
    }

    private func cursorKind(for handle: Handle, item: AnnotationItem) -> AnnotationCursorKind {
        switch handle {
        case .left, .right:
            return .resizeHorizontal
        case .top, .bottom:
            return .resizeVertical
        case .topLeft, .bottomRight:
            return .resizeDiagonalDown
        case .topRight, .bottomLeft:
            return .resizeDiagonalUp
        case .start, .end:
            guard case .line(let start, let end) = item.geometry else { return .resizeHorizontal }
            let degrees = -atan2(end.y - start.y, end.x - start.x) * 180 / .pi
            let bucket = Int((degrees / 5).rounded()) * 5
            return .resizeLine(bucket)
        }
    }

    private func setCursor(at point: CGPoint, modifiers: NSEvent.ModifierFlags) {
        guard bounds.contains(point) else { return }
        setCursorKind(resolvedCursorKind(at: point, modifierFlags: modifiers))
    }

    private func setCursorKind(_ kind: AnnotationCursorKind) {
        AnnotationCursorFactory.cursor(for: kind).set()
    }

    private func refreshCursor(
        at point: CGPoint? = nil,
        modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags
    ) {
        window?.invalidateCursorRects(for: self)
        if let point {
            setCursor(at: point, modifiers: modifiers)
        } else if let window {
            setCursor(
                at: convert(window.mouseLocationOutsideOfEventStream, from: nil),
                modifiers: modifiers
            )
        }
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .arrow)
    }
}

enum AnnotationHitTesting {
    static func contains(_ point: CGPoint, item: AnnotationItem) -> Bool {
        let tolerance = item.tool == .sequence ? CGFloat(5) : max(6, item.style.lineWidth / 2 + 3)
        switch (item.tool, item.geometry) {
        case (.rectangle, .rect(let rect)):
            if item.style.fillMode != .stroke { return rect.standardized.contains(point) }
            return nearRectBorder(point, rect: rect.standardized, tolerance: tolerance)
        case (.ellipse, .rect(let rect)):
            let rect = rect.standardized
            guard rect.width > 0, rect.height > 0 else { return false }
            let dx = (point.x - rect.midX) / (rect.width / 2)
            let dy = (point.y - rect.midY) / (rect.height / 2)
            let value = dx * dx + dy * dy
            return item.style.fillMode == .stroke ? abs(value - 1) <= tolerance / max(rect.width, rect.height) * 3 : value <= 1
        case (.line, .line(let start, let end)), (.arrow, .line(let start, let end)):
            return distanceToSegment(point, start: start, end: end) <= tolerance
        case (.pen, .path(let points)), (.mosaic, .path(let points)):
            return zip(points, points.dropFirst()).contains { distanceToSegment(point, start: $0.0, end: $0.1) <= tolerance }
        case (.text, .text(let frame, _)), (.highlight, .rect(let frame)):
            return frame.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        case (.sequence, .badge(let step)):
            if step.badgeFrame.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point) {
                return true
            }
            return !step.text.isEmpty
                && step.labelFrame.standardized.insetBy(dx: -tolerance, dy: -tolerance).contains(point)
        default:
            return false
        }
    }

    static func distanceToSegment(_ point: CGPoint, start: CGPoint, end: CGPoint) -> CGFloat {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        guard lengthSquared > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        let projection = min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let closest = CGPoint(x: start.x + projection * dx, y: start.y + projection * dy)
        return hypot(point.x - closest.x, point.y - closest.y)
    }

    private static func nearRectBorder(_ point: CGPoint, rect: CGRect, tolerance: CGFloat) -> Bool {
        guard rect.insetBy(dx: -tolerance, dy: -tolerance).contains(point) else { return false }
        return !rect.insetBy(dx: tolerance, dy: tolerance).contains(point)
    }
}

@MainActor
final class InlineAnnotationTextView: NSTextView {
    var onFinish: ((Bool) -> Void)?
    var onTextChanged: (() -> Void)?
    private var didFinish = false
    private let ownedTextStorage: NSTextStorage?
    private let ownedLayoutManager: NSLayoutManager?

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        let resolvedContainer: NSTextContainer
        if let container {
            resolvedContainer = container
            ownedTextStorage = nil
            ownedLayoutManager = nil
        } else {
            let textStorage = NSTextStorage()
            let layoutManager = NSLayoutManager()
            let textContainer = NSTextContainer(containerSize: frameRect.size)
            textContainer.widthTracksTextView = true
            textContainer.heightTracksTextView = false
            textStorage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(textContainer)
            resolvedContainer = textContainer
            ownedTextStorage = textStorage
            ownedLayoutManager = layoutManager
        }
        super.init(frame: frameRect, textContainer: resolvedContainer)
        isRichText = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isHorizontallyResizable = false
        isVerticallyResizable = false
        drawsBackground = false
        backgroundColor = .clear
        textContainerInset = CGSize(width: 5, height: 4)
        resolvedContainer.lineFragmentPadding = 0
        prepareTextContainerForCurrentSize()
        wantsLayer = true
        layer?.borderColor = NSColor.systemBlue.cgColor
        layer?.borderWidth = 1
        layer?.cornerRadius = 4
    }

    convenience override init(frame frameRect: NSRect) {
        self.init(frame: frameRect, textContainer: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func prepareTextContainerForCurrentSize() {
        guard let textContainer else { return }
        textContainer.widthTracksTextView = true
        textContainer.heightTracksTextView = false
        textContainer.containerSize = NSSize(
            width: max(1, bounds.width - textContainerInset.width * 2),
            height: .greatestFiniteMagnitude
        )
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            finish(false)
        } else if event.modifierFlags.contains(.command), event.keyCode == UInt16(kVK_Return) {
            finish(true)
        } else {
            super.keyDown(with: event)
        }
    }

    override func didChangeText() {
        super.didChangeText()
        onTextChanged?()
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result { finish(true) }
        return result
    }

    private func finish(_ commit: Bool) {
        guard !didFinish else { return }
        didFinish = true
        onFinish?(commit)
    }
}

@MainActor
final class AnnotationHoverButton: NSButton {
    static let defaultHoverDelay: TimeInterval = 0.05

    var hoverTitle: String?
    var hoverDelay = defaultHoverDelay
    var onHoverShow: ((AnnotationHoverButton, String) -> Void)?
    var onHoverHide: (() -> Void)?

    private var hoverTrackingArea: NSTrackingArea?
    private var hoverTimer: Timer?

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let trackingArea = NSTrackingArea(
            rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(trackingArea)
        hoverTrackingArea = trackingArea
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        scheduleHover()
    }

    override func mouseExited(with event: NSEvent) {
        cancelHover()
        super.mouseExited(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        cancelHover()
        super.mouseDown(with: event)
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            cancelHover()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    private func scheduleHover() {
        hoverTimer?.invalidate()
        guard hoverTitle?.isEmpty == false else { return }
        let timer = Timer(
            timeInterval: hoverDelay,
            target: self,
            selector: #selector(showHover),
            userInfo: nil,
            repeats: false
        )
        hoverTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func cancelHover() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        onHoverHide?()
    }

    @objc private func showHover() {
        hoverTimer = nil
        guard let hoverTitle, !hoverTitle.isEmpty else { return }
        onHoverShow?(self, hoverTitle)
    }
}

@MainActor
final class AnnotationHoverTooltipPresenter {
    static let fontSize: CGFloat = 16

    private let panel: NSPanel
    private let backgroundView = NSVisualEffectView()
    private let label = NSTextField(labelWithString: "")
    private weak var hostWindow: NSWindow?

    init() {
        panel = NSPanel(
            contentRect: .zero,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]

        backgroundView.material = .hudWindow
        backgroundView.blendingMode = .behindWindow
        backgroundView.state = .active
        backgroundView.wantsLayer = true
        backgroundView.layer?.cornerRadius = 7
        backgroundView.layer?.masksToBounds = true

        label.font = .systemFont(ofSize: Self.fontSize, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.maximumNumberOfLines = 1
        label.lineBreakMode = .byClipping
        backgroundView.addSubview(label)
        panel.contentView = backgroundView
    }

    func show(title: String, relativeTo view: NSView) {
        guard let window = view.window else { return }
        if hostWindow !== window {
            hostWindow?.removeChildWindow(panel)
            window.addChildWindow(panel, ordered: .above)
            hostWindow = window
        }

        label.stringValue = title
        label.sizeToFit()
        let contentSize = NSSize(
            width: ceil(label.frame.width) + 24,
            height: max(34, ceil(label.frame.height) + 14)
        )
        backgroundView.frame = NSRect(origin: .zero, size: contentSize)
        label.frame = NSRect(
            x: 12,
            y: floor((contentSize.height - label.frame.height) / 2),
            width: contentSize.width - 24,
            height: label.frame.height
        )

        let buttonRectInWindow = view.convert(view.bounds, to: nil)
        let buttonRect = window.convertToScreen(buttonRectInWindow)
        let visibleFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? buttonRect
        let gap: CGFloat = 7
        var origin = NSPoint(
            x: buttonRect.midX - contentSize.width / 2,
            y: buttonRect.maxY + gap
        )
        if origin.y + contentSize.height > visibleFrame.maxY {
            origin.y = buttonRect.minY - contentSize.height - gap
        }
        origin.x = min(
            max(origin.x, visibleFrame.minX + 4),
            visibleFrame.maxX - contentSize.width - 4
        )
        origin.y = min(
            max(origin.y, visibleFrame.minY + 4),
            visibleFrame.maxY - contentSize.height - 4
        )
        panel.setFrame(NSRect(origin: origin, size: contentSize), display: false)
        panel.orderFront(nil)
    }

    func hide() {
        panel.orderOut(nil)
    }

    func detach() {
        hide()
        hostWindow?.removeChildWindow(panel)
        hostWindow = nil
    }
}

@MainActor
final class AnnotationToolbarView: NSVisualEffectView {
    var onToolSelected: ((AnnotationTool) -> Void)?
    var onStyleChanged: ((AnnotationStyle) -> Void)?
    var onUndo: (() -> Void)?
    var onRedo: (() -> Void)?
    var onCancel: (() -> Void)?
    var onLongCapture: (() -> Void)?
    var onGIF: (() -> Void)?
    var onOCR: (() -> Void)?
    var onPin: (() -> Void)?
    var onCopy: (() -> Void)?
    var onSave: (() -> Void)?
    var onWatermarkToggle: ((Bool) -> Void)?
    var onPreferredSizeChanged: (() -> Void)?

    private var currentTool: AnnotationTool = .select
    private var contextTool: AnnotationTool = .select
    private var currentStyle = AnnotationStyle.defaultStyle(for: .rectangle)
    private var toolButtons: [AnnotationTool: NSButton] = [:]
    private let hoverTooltipPresenter = AnnotationHoverTooltipPresenter()
    private let rootStack = NSStackView()
    private let styleRow = NSStackView()
    private let colorPaletteStack = NSStackView()
    private let presetColors: [RGBAColor] = [
        .annotationRed,
        RGBAColor(red: 1, green: 0.584, blue: 0),
        RGBAColor(red: 1, green: 0.8, blue: 0),
        RGBAColor(red: 0.204, green: 0.78, blue: 0.349),
        RGBAColor(red: 0.196, green: 0.678, blue: 0.902),
        RGBAColor(red: 0, green: 0.478, blue: 1),
        RGBAColor(red: 0.12, green: 0.12, blue: 0.12)
    ]
    private var presetColorButtons: [NSButton] = []
    private let sizeLabel = NSTextField(labelWithString: L.text("粗细"))
    private lazy var sizeSlider = NSSlider(value: 3, minValue: 1, maxValue: 48, target: self, action: #selector(styleControlChanged))
    private let opacityLabel = NSTextField(labelWithString: L.text("透明度"))
    private lazy var opacitySlider = NSSlider(value: 1, minValue: 0.1, maxValue: 1, target: self, action: #selector(styleControlChanged))
    private lazy var patternPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var variantPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private lazy var undoButton = makeButton(symbol: "arrow.uturn.backward", title: L.text("撤销"), action: #selector(undoAction))
    private lazy var redoButton = makeButton(symbol: "arrow.uturn.forward", title: L.text("重做"), action: #selector(redoAction))
    private lazy var cancelButton = makeButton(symbol: "xmark", title: L.text("取消 (Esc)"), action: #selector(cancelAction))
    private lazy var longCaptureButton = makeButton(
        symbol: "rectangle.expand.vertical",
        title: L.text("长截图"),
        action: #selector(longCaptureAction)
    )
    private lazy var gifButton: AnnotationHoverButton = {
        makeButton(symbol: "record.circle", title: L.text("录屏"), action: #selector(gifAction))
    }()
    private lazy var ocrButton = makeButton(symbol: "text.viewfinder", title: L.text("识别文字"), action: #selector(ocrAction))
    private lazy var pinButton = makeButton(symbol: "pin", title: L.text("贴图"), action: #selector(pinAction))
    private lazy var watermarkButton = makeButton(symbol: "drop", title: L.text("水印"), action: #selector(watermarkAction))
    private lazy var copyButton = makeButton(symbol: "doc.on.doc", title: L.text("复制 (⌘C)"), action: #selector(copyAction))
    private lazy var saveButton = makeButton(symbol: "square.and.arrow.down", title: L.text("保存 (⌘S)"), action: #selector(saveAction))
    private let busyIndicator = NSProgressIndicator()
    private let busyLabel = NSTextField(labelWithString: L.text("正在冻结截图…"))
    private var isBusy = false
    private var isLongCaptureAvailable = true
    private var isGIFAvailable = true
    private var isWatermarkAvailable = false
    private var isWatermarkEnabled = false
    private var canUndo = false
    private var canRedo = false
    private var isPinEditingMode = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true
        configureLayout()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if newWindow == nil {
            hoverTooltipPresenter.detach()
        }
        super.viewWillMove(toWindow: newWindow)
    }

    func setTool(_ tool: AnnotationTool, style: AnnotationStyle) {
        currentTool = tool
        contextTool = tool
        currentStyle = style
        for (candidate, button) in toolButtons {
            button.state = candidate == tool ? .on : .off
            button.contentTintColor = candidate == tool ? .systemBlue : .labelColor
        }
        refreshStyleControls()
    }

    func setSelectedItem(_ item: AnnotationItem?) {
        guard let item else {
            contextTool = currentTool
            refreshStyleControls()
            return
        }
        contextTool = item.tool
        currentStyle = item.style
        refreshStyleControls(for: item.tool)
    }

    func setUndoEnabled(_ undoEnabled: Bool, redoEnabled: Bool) {
        canUndo = undoEnabled
        canRedo = redoEnabled
        undoButton.isEnabled = !isBusy && canUndo
        redoButton.isEnabled = !isBusy && canRedo
    }

    func setLongCaptureEnabled(_ enabled: Bool) {
        isLongCaptureAvailable = enabled
        longCaptureButton.isEnabled = !isBusy && enabled
    }

    func setGIFEnabled(_ enabled: Bool) {
        isGIFAvailable = enabled
        gifButton.isEnabled = !isBusy && enabled
    }

    func setWatermarkAvailable(_ available: Bool, enabled: Bool) {
        guard !isPinEditingMode else {
            watermarkButton.isHidden = true
            return
        }
        isWatermarkAvailable = available
        isWatermarkEnabled = enabled
        watermarkButton.isHidden = !available
        watermarkButton.state = enabled ? .on : .off
        watermarkButton.contentTintColor = enabled ? .systemBlue : .labelColor
        watermarkButton.toolTip = enabled ? L.text("关闭本次截图水印") : L.text("开启本次截图水印")
        watermarkButton.isEnabled = !isBusy && available
        updatePreferredSize()
    }

    func setPinEditingMode() {
        isPinEditingMode = true
        longCaptureButton.isHidden = true
        gifButton.isHidden = true
        ocrButton.isHidden = true
        pinButton.isHidden = true
        watermarkButton.isHidden = true
        copyButton.isHidden = true
        saveButton.image = NSImage(systemSymbolName: "checkmark", accessibilityDescription: L.text("完成"))?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        saveButton.hoverTitle = L.text("完成")
        saveButton.setAccessibilityLabel(L.text("完成"))
        saveButton.contentTintColor = .systemBlue
        updatePreferredSize()
    }

    func setBusy(_ busy: Bool, message: String = L.text("正在冻结截图…")) {
        isBusy = busy
        busyLabel.stringValue = message
        for button in toolButtons.values { button.isEnabled = !busy }
        undoButton.isEnabled = !busy && canUndo
        redoButton.isEnabled = !busy && canRedo
        longCaptureButton.isEnabled = !busy && isLongCaptureAvailable
        gifButton.isEnabled = !busy && isGIFAvailable
        ocrButton.isEnabled = !busy
        pinButton.isEnabled = !busy
        watermarkButton.isEnabled = !busy && isWatermarkAvailable
        copyButton.isEnabled = !busy
        saveButton.isEnabled = !busy
        cancelButton.isEnabled = true
        if busy {
            busyIndicator.startAnimation(nil)
        } else {
            busyIndicator.stopAnimation(nil)
        }
        refreshStyleControls()
    }

    private func configureLayout() {
        let mainRow = NSStackView()
        mainRow.orientation = .horizontal
        mainRow.alignment = .centerY
        mainRow.spacing = 2

        let toolDefinitions: [(AnnotationTool, String)] = [
            (.select, "cursorarrow"), (.rectangle, "rectangle"), (.ellipse, "circle"),
            (.line, "line.diagonal"), (.arrow, "arrow.up.right"), (.pen, "pencil.tip"),
            (.text, "textformat"), (.sequence, "1.circle"),
            (.mosaic, "checkerboard.rectangle"), (.highlight, "flashlight.on.fill")
        ]
        for (tool, symbol) in toolDefinitions {
            let button = makeButton(
                symbol: symbol,
                title: tool.title,
                action: #selector(toolAction(_:))
            )
            button.setAccessibilityLabel(L.format("%@，快捷键 %@", tool.title, String(tool.shortcut).uppercased()))
            button.identifier = NSUserInterfaceItemIdentifier(tool.rawValue)
            button.setButtonType(.toggle)
            toolButtons[tool] = button
            mainRow.addArrangedSubview(button)
        }

        mainRow.addArrangedSubview(makeSeparator())
        mainRow.addArrangedSubview(undoButton)
        mainRow.addArrangedSubview(redoButton)
        mainRow.addArrangedSubview(makeSeparator())
        mainRow.addArrangedSubview(cancelButton)
        longCaptureButton.identifier = NSUserInterfaceItemIdentifier("longCaptureAction")
        mainRow.addArrangedSubview(longCaptureButton)
        gifButton.identifier = NSUserInterfaceItemIdentifier("gifAction")
        mainRow.addArrangedSubview(gifButton)
        ocrButton.identifier = NSUserInterfaceItemIdentifier("ocrAction")
        mainRow.addArrangedSubview(ocrButton)
        pinButton.identifier = NSUserInterfaceItemIdentifier("pinAction")
        mainRow.addArrangedSubview(pinButton)
        watermarkButton.identifier = NSUserInterfaceItemIdentifier("watermarkAction")
        watermarkButton.setButtonType(.toggle)
        watermarkButton.isHidden = true
        mainRow.addArrangedSubview(watermarkButton)
        copyButton.identifier = NSUserInterfaceItemIdentifier("copyAction")
        mainRow.addArrangedSubview(copyButton)
        saveButton.contentTintColor = .systemBlue
        saveButton.identifier = NSUserInterfaceItemIdentifier("saveAction")
        mainRow.addArrangedSubview(saveButton)

        styleRow.orientation = .horizontal
        styleRow.alignment = .centerY
        styleRow.spacing = 6
        colorPaletteStack.orientation = .horizontal
        colorPaletteStack.alignment = .centerY
        colorPaletteStack.spacing = 5
        for (index, color) in presetColors.enumerated() {
            let button = NSButton(frame: NSRect(x: 0, y: 0, width: 19, height: 19))
            button.title = ""
            button.isBordered = false
            button.refusesFirstResponder = true
            button.tag = index
            button.identifier = NSUserInterfaceItemIdentifier("annotationColor.\(index)")
            button.toolTip = L.text("选择标注颜色")
            button.target = self
            button.action = #selector(presetColorAction(_:))
            button.translatesAutoresizingMaskIntoConstraints = false
            button.widthAnchor.constraint(equalToConstant: 19).isActive = true
            button.heightAnchor.constraint(equalToConstant: 19).isActive = true
            button.wantsLayer = true
            button.layer?.cornerRadius = 9.5
            button.layer?.backgroundColor = color.nsColor.cgColor
            presetColorButtons.append(button)
            colorPaletteStack.addArrangedSubview(button)
        }
        sizeSlider.translatesAutoresizingMaskIntoConstraints = false
        opacitySlider.translatesAutoresizingMaskIntoConstraints = false
        sizeSlider.widthAnchor.constraint(equalToConstant: 90).isActive = true
        opacitySlider.widthAnchor.constraint(equalToConstant: 75).isActive = true
        patternPopup.target = self
        patternPopup.action = #selector(styleControlChanged)
        variantPopup.target = self
        variantPopup.action = #selector(styleControlChanged)
        busyIndicator.style = .spinning
        busyIndicator.controlSize = .small
        busyIndicator.isDisplayedWhenStopped = false
        busyLabel.textColor = .secondaryLabelColor
        styleRow.addArrangedSubview(busyIndicator)
        styleRow.addArrangedSubview(busyLabel)
        styleRow.addArrangedSubview(colorPaletteStack)
        styleRow.addArrangedSubview(sizeLabel)
        styleRow.addArrangedSubview(sizeSlider)
        styleRow.addArrangedSubview(opacityLabel)
        styleRow.addArrangedSubview(opacitySlider)
        styleRow.addArrangedSubview(patternPopup)
        styleRow.addArrangedSubview(variantPopup)

        rootStack.addArrangedSubview(mainRow)
        rootStack.addArrangedSubview(styleRow)
        rootStack.orientation = .vertical
        rootStack.alignment = .centerX
        rootStack.spacing = 5
        rootStack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(rootStack)
        NSLayoutConstraint.activate([
            rootStack.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 8),
            rootStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -8),
            rootStack.centerXAnchor.constraint(equalTo: centerXAnchor),
            rootStack.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            rootStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
        setTool(.select, style: .defaultStyle(for: .rectangle))
        setUndoEnabled(false, redoEnabled: false)
    }

    private func refreshStyleControls(for overrideTool: AnnotationTool? = nil) {
        let tool = overrideTool ?? contextTool
        busyIndicator.isHidden = !isBusy
        busyLabel.isHidden = !isBusy
        colorPaletteStack.isHidden = isBusy
        sizeLabel.isHidden = isBusy
        sizeSlider.isHidden = isBusy
        opacityLabel.isHidden = isBusy
        opacitySlider.isHidden = isBusy
        patternPopup.isHidden = isBusy
        variantPopup.isHidden = isBusy
        styleRow.isHidden = !isBusy && tool == .select
        if isBusy {
            updatePreferredSize()
            return
        }
        guard tool != .select else {
            updatePreferredSize()
            return
        }

        refreshPresetColorSelection()
        opacitySlider.doubleValue = currentStyle.opacity
        colorPaletteStack.isHidden = tool == .mosaic || tool == .highlight
        opacityLabel.isHidden = tool == .highlight
        opacitySlider.isHidden = tool == .highlight
        sizeLabel.isHidden = tool == .highlight
        sizeSlider.isHidden = tool == .highlight

        switch tool {
        case .text:
            sizeLabel.stringValue = L.text("字号")
            sizeSlider.minValue = 10
            sizeSlider.maxValue = 72
            sizeSlider.doubleValue = currentStyle.fontSize
        case .sequence:
            sizeLabel.stringValue = L.text("大小")
            sizeSlider.minValue = 20
            sizeSlider.maxValue = 80
            sizeSlider.doubleValue = currentStyle.lineWidth
        case .mosaic:
            sizeLabel.stringValue = L.text("笔宽")
            sizeSlider.minValue = 8
            sizeSlider.maxValue = 80
            sizeSlider.doubleValue = currentStyle.lineWidth
        default:
            sizeLabel.stringValue = L.text("粗细")
            sizeSlider.minValue = 1
            sizeSlider.maxValue = 24
            sizeSlider.doubleValue = currentStyle.lineWidth
        }

        configurePatternPopup(for: tool)
        configureVariantPopup(for: tool)
        updatePreferredSize()
    }

    private func configurePatternPopup(for tool: AnnotationTool) {
        patternPopup.removeAllItems()
        patternPopup.isHidden = false
        switch tool {
        case .rectangle, .ellipse, .line, .arrow:
            patternPopup.addItems(withTitles: [L.text("实线"), L.text("虚线"), L.text("点线")])
            patternPopup.selectItem(at: AnnotationLinePattern.allCases.firstIndex(of: currentStyle.linePattern) ?? 0)
        case .mosaic:
            patternPopup.addItems(withTitles: [L.text("小颗粒"), L.text("中颗粒"), L.text("大颗粒")])
            patternPopup.selectItem(at: currentStyle.mosaicStrength < 10 ? 0 : (currentStyle.mosaicStrength < 20 ? 1 : 2))
        case .highlight:
            patternPopup.addItems(withTitles: [L.text("暗度 35%"), L.text("暗度 55%"), L.text("暗度 70%")])
            patternPopup.selectItem(at: currentStyle.highlightDimOpacity < 0.45 ? 0 : (currentStyle.highlightDimOpacity < 0.65 ? 1 : 2))
        default:
            patternPopup.isHidden = true
        }
    }

    private func configureVariantPopup(for tool: AnnotationTool) {
        variantPopup.removeAllItems()
        variantPopup.isHidden = false
        switch tool {
        case .rectangle, .ellipse:
            variantPopup.addItems(withTitles: [L.text("仅描边"), L.text("仅填充"), L.text("描边 + 填充")])
            variantPopup.selectItem(at: AnnotationFillMode.allCases.firstIndex(of: currentStyle.fillMode) ?? 0)
        case .arrow:
            variantPopup.addItems(withTitles: [L.text("单箭头"), L.text("双箭头")])
            variantPopup.selectItem(at: currentStyle.arrowHeads == .end ? 0 : 1)
        case .text:
            variantPopup.addItems(withTitles: [L.text("普通"), L.text("粗体"), L.text("背景"), L.text("粗体 + 背景")])
            let index = (currentStyle.isBold ? 1 : 0) + (currentStyle.hasTextBackground ? 2 : 0)
            variantPopup.selectItem(at: index)
        case .mosaic:
            variantPopup.addItems(withTitles: [L.text("像素化"), L.text("模糊")])
            variantPopup.selectItem(at: currentStyle.mosaicMode == .pixelate ? 0 : 1)
        case .highlight:
            variantPopup.addItems(withTitles: [L.text("矩形高亮"), L.text("椭圆高亮")])
            variantPopup.selectItem(at: currentStyle.highlightShape == .rectangle ? 0 : 1)
        default:
            variantPopup.isHidden = true
        }
    }

    private func updatePreferredSize() {
        let preferredHeight: CGFloat = styleRow.isHidden ? 40 : 72
        layoutSubtreeIfNeeded()
        let preferredWidth = min(720, max(1, ceil(rootStack.fittingSize.width) + 16))
        guard abs(frame.height - preferredHeight) > 0.5
                || abs(frame.width - preferredWidth) > 0.5 else { return }
        setFrameSize(NSSize(width: preferredWidth, height: preferredHeight))
        onPreferredSizeChanged?()
    }

    @objc private func toolAction(_ sender: NSButton) {
        guard let identifier = sender.identifier?.rawValue,
              let tool = AnnotationTool(rawValue: identifier) else { return }
        onToolSelected?(tool)
    }

    @objc private func styleControlChanged() {
        let tool = contextTool
        guard tool != .select else { return }
        currentStyle.opacity = CGFloat(opacitySlider.doubleValue)
        switch tool {
        case .text:
            currentStyle.fontSize = CGFloat(sizeSlider.doubleValue)
        case .sequence, .mosaic:
            currentStyle.lineWidth = CGFloat(sizeSlider.doubleValue)
        case .highlight:
            break
        default:
            currentStyle.lineWidth = CGFloat(sizeSlider.doubleValue)
        }

        switch tool {
        case .rectangle, .ellipse, .line, .arrow:
            currentStyle.linePattern = AnnotationLinePattern.allCases[max(0, patternPopup.indexOfSelectedItem)]
        case .mosaic:
            currentStyle.mosaicStrength = [8, 14, 24][max(0, patternPopup.indexOfSelectedItem)]
        case .highlight:
            currentStyle.highlightDimOpacity = [0.35, 0.55, 0.7][max(0, patternPopup.indexOfSelectedItem)]
        default:
            break
        }

        switch tool {
        case .rectangle, .ellipse:
            currentStyle.fillMode = AnnotationFillMode.allCases[max(0, variantPopup.indexOfSelectedItem)]
        case .arrow:
            currentStyle.arrowHeads = variantPopup.indexOfSelectedItem == 0 ? .end : .both
        case .text:
            currentStyle.isBold = variantPopup.indexOfSelectedItem == 1 || variantPopup.indexOfSelectedItem == 3
            currentStyle.hasTextBackground = variantPopup.indexOfSelectedItem >= 2
        case .mosaic:
            currentStyle.mosaicMode = variantPopup.indexOfSelectedItem == 0 ? .pixelate : .blur
        case .highlight:
            currentStyle.highlightShape = variantPopup.indexOfSelectedItem == 0 ? .rectangle : .ellipse
        default:
            break
        }
        onStyleChanged?(currentStyle)
    }

    @objc private func presetColorAction(_ sender: NSButton) {
        guard presetColors.indices.contains(sender.tag), contextTool != .select else { return }
        currentStyle.color = presetColors[sender.tag]
        refreshPresetColorSelection()
        onStyleChanged?(currentStyle)
    }

    private func refreshPresetColorSelection() {
        for (index, button) in presetColorButtons.enumerated() {
            let candidate = presetColors[index]
            let selected = abs(candidate.red - currentStyle.color.red) < 0.01
                && abs(candidate.green - currentStyle.color.green) < 0.01
                && abs(candidate.blue - currentStyle.color.blue) < 0.01
            button.layer?.borderWidth = selected ? 2.5 : 1
            button.layer?.borderColor = selected
                ? NSColor.controlAccentColor.cgColor
                : NSColor.white.withAlphaComponent(0.55).cgColor
        }
    }

    @objc private func undoAction() { onUndo?() }
    @objc private func redoAction() { onRedo?() }
    @objc private func cancelAction() { onCancel?() }
    @objc private func longCaptureAction() { onLongCapture?() }
    @objc private func gifAction() { onGIF?() }
    @objc private func ocrAction() { onOCR?() }
    @objc private func pinAction() { onPin?() }
    @objc private func watermarkAction() {
        isWatermarkEnabled.toggle()
        setWatermarkAvailable(isWatermarkAvailable, enabled: isWatermarkEnabled)
        onWatermarkToggle?(isWatermarkEnabled)
    }
    @objc private func copyAction() { onCopy?() }
    @objc private func saveAction() { onSave?() }

    /// Renders short text (e.g. "GIF") inside a rounded-rectangle badge
    /// as a template image so it blends with the toolbar icon color.
    private func makeTextIcon(_ text: String, fontSize: CGFloat = 11) -> NSImage {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
            .foregroundColor: NSColor.black
        ]
        let textSize = (text as NSString).size(withAttributes: attributes)
        let padding: CGFloat = 3
        let badgeSize = NSSize(
            width: textSize.width + padding * 2,
            height: textSize.height + padding * 2
        )
        let image = NSImage(size: badgeSize)
        image.lockFocus()

        // Rounded-rectangle border
        let badgePath = NSBezierPath(
            roundedRect: NSRect(origin: .zero, size: badgeSize),
            xRadius: 4,
            yRadius: 4
        )
        NSColor.black.setStroke()
        badgePath.lineWidth = 1
        badgePath.stroke()

        // Centered text
        (text as NSString).draw(
            at: NSPoint(
                x: (badgeSize.width - textSize.width) / 2,
                y: (badgeSize.height - textSize.height) / 2
            ),
            withAttributes: attributes
        )
        image.unlockFocus()
        image.isTemplate = true
        return image
    }

    private func makeButton(symbol: String, title: String, action: Selector) -> AnnotationHoverButton {
        let button = AnnotationHoverButton(frame: NSRect(x: 0, y: 0, width: 28, height: 28))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: title)?
            .withSymbolConfiguration(.init(pointSize: 16, weight: .medium))
        if button.image == nil { button.title = String(title.prefix(1)) }
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.hoverTitle = title
        button.onHoverShow = { [weak self] button, title in
            self?.hoverTooltipPresenter.show(title: title, relativeTo: button)
        }
        button.onHoverHide = { [weak self] in
            self?.hoverTooltipPresenter.hide()
        }
        button.setAccessibilityLabel(title)
        button.target = self
        button.action = action
        button.widthAnchor.constraint(equalToConstant: 28).isActive = true
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
