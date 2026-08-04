import AppKit
import Foundation

enum AnnotationTool: String, CaseIterable, Codable {
    case select
    case rectangle
    case ellipse
    case line
    case arrow
    case pen
    case text
    case sequence
    case mosaic
    case highlight

    static let drawingTools: [AnnotationTool] = [
        .rectangle, .ellipse, .line, .arrow, .pen,
        .text, .sequence, .mosaic, .highlight
    ]

    var title: String {
        switch self {
        case .select: "选择"
        case .rectangle: "矩形"
        case .ellipse: "圆形"
        case .line: "直线"
        case .arrow: "箭头"
        case .pen: "画笔"
        case .text: "文字"
        case .sequence: "步骤"
        case .mosaic: "马赛克"
        case .highlight: "高亮"
        }
    }

    var shortcut: Character {
        switch self {
        case .select: "v"
        case .rectangle: "r"
        case .ellipse: "o"
        case .line: "l"
        case .arrow: "a"
        case .pen: "p"
        case .text: "t"
        case .sequence: "n"
        case .mosaic: "m"
        case .highlight: "h"
        }
    }
}

struct RGBAColor: Codable, Equatable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat

    static let annotationRed = RGBAColor(red: 1, green: 0.231, blue: 0.188, alpha: 1)

    init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    init(_ color: NSColor) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        red = converted.redComponent
        green = converted.greenComponent
        blue = converted.blueComponent
        alpha = converted.alphaComponent
    }

    var nsColor: NSColor {
        NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }

    var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }
}

enum AnnotationLinePattern: String, Codable, CaseIterable {
    case solid
    case dashed
    case dotted
}

enum AnnotationFillMode: String, Codable, CaseIterable {
    case stroke
    case fill
    case strokeAndFill
}

enum ArrowHeadMode: String, Codable, CaseIterable {
    case end
    case both
}

enum MosaicMode: String, Codable, CaseIterable {
    case pixelate
    case blur
}

enum HighlightShape: String, Codable, CaseIterable {
    case rectangle
    case ellipse
}

struct AnnotationStyle: Codable, Equatable {
    var color: RGBAColor = .annotationRed
    var opacity: CGFloat = 1
    var lineWidth: CGFloat = 3
    var linePattern: AnnotationLinePattern = .solid
    var fillMode: AnnotationFillMode = .stroke
    var arrowHeads: ArrowHeadMode = .end
    var fontSize: CGFloat = 18
    var isBold = false
    var hasTextBackground = false
    var mosaicMode: MosaicMode = .pixelate
    var mosaicStrength: CGFloat = 12
    var highlightShape: HighlightShape = .rectangle
    var highlightDimOpacity: CGFloat = 0.55

    static func defaultStyle(for tool: AnnotationTool) -> AnnotationStyle {
        var style = AnnotationStyle()
        switch tool {
        case .pen:
            style.lineWidth = 4
        case .text:
            style.fontSize = 18
        case .sequence:
            style.lineWidth = 28
            style.isBold = true
        case .mosaic:
            style.lineWidth = 28
            style.mosaicStrength = 12
        case .highlight:
            style.highlightDimOpacity = 0.55
        default:
            break
        }
        return style
    }

    var isValid: Bool {
        color.isValid
            && opacity.isFinite && (0...1).contains(opacity)
            && lineWidth.isFinite && (0.5...160).contains(lineWidth)
            && fontSize.isFinite && (8...144).contains(fontSize)
            && mosaicStrength.isFinite && (2...80).contains(mosaicStrength)
            && highlightDimOpacity.isFinite && (0...0.9).contains(highlightDimOpacity)
    }
}

struct StepAnnotationGeometry: Equatable {
    var badgeFrame: CGRect
    var number: Int
    var labelFrame: CGRect
    var text: String

    var visibleBounds: CGRect {
        let badge = badgeFrame.standardized
        guard !text.isEmpty else { return badge }
        return badge.union(labelFrame.standardized)
    }
}

enum AnnotationGeometry: Equatable {
    case rect(CGRect)
    case line(start: CGPoint, end: CGPoint)
    case path([CGPoint])
    case text(frame: CGRect, value: String)
    case badge(StepAnnotationGeometry)

    var bounds: CGRect {
        switch self {
        case .rect(let rect), .text(let rect, _):
            return rect.standardized
        case .badge(let step):
            return step.visibleBounds
        case .line(let start, let end):
            return CGRect(
                x: min(start.x, end.x), y: min(start.y, end.y),
                width: abs(end.x - start.x), height: abs(end.y - start.y)
            )
        case .path(let points):
            guard let first = points.first else { return .zero }
            return points.dropFirst().reduce(CGRect(origin: first, size: .zero)) { partial, point in
                partial.union(CGRect(origin: point, size: .zero))
            }
        }
    }

    func translated(by offset: CGPoint) -> AnnotationGeometry {
        switch self {
        case .rect(let rect):
            return .rect(rect.offsetBy(dx: offset.x, dy: offset.y))
        case .line(let start, let end):
            return .line(
                start: CGPoint(x: start.x + offset.x, y: start.y + offset.y),
                end: CGPoint(x: end.x + offset.x, y: end.y + offset.y)
            )
        case .path(let points):
            return .path(points.map { CGPoint(x: $0.x + offset.x, y: $0.y + offset.y) })
        case .text(let frame, let value):
            return .text(frame: frame.offsetBy(dx: offset.x, dy: offset.y), value: value)
        case .badge(var step):
            step.badgeFrame = step.badgeFrame.offsetBy(dx: offset.x, dy: offset.y)
            step.labelFrame = step.labelFrame.offsetBy(dx: offset.x, dy: offset.y)
            return .badge(step)
        }
    }

    func scaled(from source: CGRect, to destination: CGRect) -> AnnotationGeometry {
        let source = source.standardized
        let destination = destination.standardized
        let sx = source.width > 0 ? destination.width / source.width : 1
        let sy = source.height > 0 ? destination.height / source.height : 1
        func transform(_ point: CGPoint) -> CGPoint {
            CGPoint(
                x: destination.minX + (point.x - source.minX) * sx,
                y: destination.minY + (point.y - source.minY) * sy
            )
        }

        switch self {
        case .rect:
            return .rect(destination)
        case .line(let start, let end):
            return .line(start: transform(start), end: transform(end))
        case .path(let points):
            return .path(points.map(transform))
        case .text(_, let value):
            return .text(frame: destination, value: value)
        case .badge(var step):
            step.badgeFrame = CGRect(
                origin: transform(step.badgeFrame.origin),
                size: CGSize(width: step.badgeFrame.width * sx, height: step.badgeFrame.height * sy)
            ).standardized
            step.labelFrame = CGRect(
                origin: transform(step.labelFrame.origin),
                size: CGSize(width: step.labelFrame.width * sx, height: step.labelFrame.height * sy)
            ).standardized
            return .badge(step)
        }
    }
}

struct AnnotationItem: Identifiable, Equatable {
    let id: UUID
    var tool: AnnotationTool
    var geometry: AnnotationGeometry
    var style: AnnotationStyle

    init(
        id: UUID = UUID(),
        tool: AnnotationTool,
        geometry: AnnotationGeometry,
        style: AnnotationStyle
    ) {
        self.id = id
        self.tool = tool
        self.geometry = geometry
        self.style = style
    }

    var bounds: CGRect {
        let inset = tool == .sequence ? CGFloat(2) : max(2, style.lineWidth / 2)
        return geometry.bounds.insetBy(dx: -inset, dy: -inset)
    }
}

struct AnnotationDocumentState: Equatable {
    var items: [AnnotationItem] = []
    var nextSequenceNumber = 1
}

@MainActor
final class AnnotationDocument {
    private struct ContentSnapshot {
        var geometry: AnnotationGeometry
        var fontSize: CGFloat?
        var lineWidth: CGFloat?
    }

    private(set) var state = AnnotationDocumentState()
    private(set) var selectedID: UUID?
    let undoManager = UndoManager()

    init() {
        undoManager.groupsByEvent = false
    }

    var items: [AnnotationItem] { state.items }
    var selectedItem: AnnotationItem? { state.items.first { $0.id == selectedID } }

    func select(_ id: UUID?) {
        selectedID = id
    }

    @discardableResult
    func add(tool: AnnotationTool, geometry: AnnotationGeometry, style: AnnotationStyle) -> AnnotationItem {
        let previousNextSequenceNumber = state.nextSequenceNumber
        let resolvedGeometry: AnnotationGeometry
        if tool == .sequence {
            if case .badge(var step) = geometry {
                step.number = state.nextSequenceNumber
                resolvedGeometry = .badge(step)
            } else {
                let frame = geometry.bounds
                resolvedGeometry = .badge(StepAnnotationGeometry(
                    badgeFrame: frame,
                    number: state.nextSequenceNumber,
                    labelFrame: frame,
                    text: ""
                ))
            }
            state.nextSequenceNumber += 1
        } else {
            resolvedGeometry = geometry
        }
        let item = AnnotationItem(tool: tool, geometry: resolvedGeometry, style: style)
        state.items.append(item)
        selectedID = item.id
        registerRemovalUndo(
            itemID: item.id,
            restoringNextSequenceNumber: previousNextSequenceNumber,
            actionName: "添加标注"
        )
        return item
    }

    func deleteSelected() {
        guard let selectedID,
              let index = state.items.firstIndex(where: { $0.id == selectedID }) else { return }
        let item = state.items.remove(at: index)
        registerInsertionUndo(
            item: item,
            index: index,
            restoringNextSequenceNumber: state.nextSequenceNumber,
            actionName: "删除标注"
        )
        self.selectedID = nil
    }

    func updateContent(
        _ item: AnnotationItem,
        actionName: String = "修改标注",
        includesFontSize: Bool = false,
        includesLineWidth: Bool = false
    ) {
        guard let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        let previous = contentSnapshot(
            of: state.items[index],
            includesFontSize: includesFontSize,
            includesLineWidth: includesLineWidth
        )
        guard previous.geometry != item.geometry
                || (includesFontSize && previous.fontSize != item.style.fontSize)
                || (includesLineWidth && previous.lineWidth != item.style.lineWidth) else { return }
        state.items[index].geometry = item.geometry
        if includesFontSize { state.items[index].style.fontSize = item.style.fontSize }
        if includesLineWidth { state.items[index].style.lineWidth = item.style.lineWidth }
        selectedID = item.id
        registerContentUndo(
            itemID: item.id,
            target: previous,
            includesFontSize: includesFontSize,
            includesLineWidth: includesLineWidth,
            actionName: actionName
        )
    }

    func updateContentWithoutUndo(_ item: AnnotationItem) {
        guard let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        state.items[index].geometry = item.geometry
        state.items[index].style = item.style
        selectedID = item.id
    }

    func updateStyle(_ style: AnnotationStyle, for itemID: UUID) {
        guard let index = state.items.firstIndex(where: { $0.id == itemID }) else { return }
        state.items[index].style = style
        selectedID = itemID
    }

    func updateLive(_ item: AnnotationItem) {
        guard let index = state.items.firstIndex(where: { $0.id == item.id }) else { return }
        state.items[index] = item
        selectedID = item.id
    }

    func commitLiveChange(
        from originalState: AnnotationDocumentState,
        actionName: String,
        includesFontSize: Bool = false,
        includesLineWidth: Bool = false
    ) {
        guard let itemID = selectedID,
              let original = originalState.items.first(where: { $0.id == itemID }),
              let current = state.items.first(where: { $0.id == itemID }) else { return }
        let target = contentSnapshot(
            of: original,
            includesFontSize: includesFontSize,
            includesLineWidth: includesLineWidth
        )
        guard target.geometry != current.geometry
                || (includesFontSize && target.fontSize != current.style.fontSize)
                || (includesLineWidth && target.lineWidth != current.style.lineWidth) else { return }
        registerContentUndo(
            itemID: itemID,
            target: target,
            includesFontSize: includesFontSize,
            includesLineWidth: includesLineWidth,
            actionName: actionName
        )
    }

    func replaceStateForTesting(_ state: AnnotationDocumentState) {
        self.state = state
        selectedID = nil
    }

    func undo() {
        undoManager.undo()
    }

    func redo() {
        undoManager.redo()
    }

    private func contentSnapshot(
        of item: AnnotationItem,
        includesFontSize: Bool,
        includesLineWidth: Bool
    ) -> ContentSnapshot {
        ContentSnapshot(
            geometry: item.geometry,
            fontSize: includesFontSize ? item.style.fontSize : nil,
            lineWidth: includesLineWidth ? item.style.lineWidth : nil
        )
    }

    private func registerContentUndo(
        itemID: UUID,
        target: ContentSnapshot,
        includesFontSize: Bool,
        includesLineWidth: Bool,
        actionName: String
    ) {
        registerUndo(actionName: actionName) { document in
            guard let index = document.state.items.firstIndex(where: { $0.id == itemID }) else { return }
            let inverse = document.contentSnapshot(
                of: document.state.items[index],
                includesFontSize: includesFontSize,
                includesLineWidth: includesLineWidth
            )
            document.state.items[index].geometry = target.geometry
            if includesFontSize, let fontSize = target.fontSize {
                document.state.items[index].style.fontSize = fontSize
            }
            if includesLineWidth, let lineWidth = target.lineWidth {
                document.state.items[index].style.lineWidth = lineWidth
            }
            document.selectedID = itemID
            document.registerContentUndo(
                itemID: itemID,
                target: inverse,
                includesFontSize: includesFontSize,
                includesLineWidth: includesLineWidth,
                actionName: actionName
            )
        }
    }

    private func registerRemovalUndo(
        itemID: UUID,
        restoringNextSequenceNumber: Int,
        actionName: String
    ) {
        registerUndo(actionName: actionName) { document in
            guard let index = document.state.items.firstIndex(where: { $0.id == itemID }) else { return }
            let item = document.state.items.remove(at: index)
            let inverseNextSequenceNumber = document.state.nextSequenceNumber
            document.state.nextSequenceNumber = restoringNextSequenceNumber
            if document.selectedID == itemID { document.selectedID = nil }
            document.registerInsertionUndo(
                item: item,
                index: index,
                restoringNextSequenceNumber: inverseNextSequenceNumber,
                actionName: actionName
            )
        }
    }

    private func registerInsertionUndo(
        item: AnnotationItem,
        index: Int,
        restoringNextSequenceNumber: Int,
        actionName: String
    ) {
        registerUndo(actionName: actionName) { document in
            let inverseNextSequenceNumber = document.state.nextSequenceNumber
            let insertionIndex = min(max(index, 0), document.state.items.count)
            document.state.items.insert(item, at: insertionIndex)
            document.state.nextSequenceNumber = restoringNextSequenceNumber
            document.selectedID = item.id
            document.registerRemovalUndo(
                itemID: item.id,
                restoringNextSequenceNumber: inverseNextSequenceNumber,
                actionName: actionName
            )
        }
    }

    private func registerUndo(
        actionName: String,
        handler: @escaping (AnnotationDocument) -> Void
    ) {
        let startsGroup = undoManager.groupingLevel == 0
        if startsGroup { undoManager.beginUndoGrouping() }
        undoManager.registerUndo(withTarget: self, handler: handler)
        undoManager.setActionName(actionName)
        if startsGroup { undoManager.endUndoGrouping() }
    }
}

enum AnnotationStylePreferences {
    private static let encoder = JSONEncoder()
    private static let decoder = JSONDecoder()

    static func load(for tool: AnnotationTool, defaults: UserDefaults = .standard) -> AnnotationStyle {
        guard tool != .select,
              let data = defaults.data(forKey: key(for: tool)),
              let style = try? decoder.decode(AnnotationStyle.self, from: data),
              style.isValid else {
            return .defaultStyle(for: tool)
        }
        return style
    }

    static func save(_ style: AnnotationStyle, for tool: AnnotationTool, defaults: UserDefaults = .standard) {
        guard tool != .select, style.isValid, let data = try? encoder.encode(style) else { return }
        defaults.set(data, forKey: key(for: tool))
    }

    private static func key(for tool: AnnotationTool) -> String {
        "annotation.style.\(tool.rawValue)"
    }
}
