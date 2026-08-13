import AppKit
import CoreImage
import Foundation

enum AnnotationRenderer {
    static func render(
        baseImage: CGImage,
        canvasSize: CGSize,
        items: [AnnotationItem]
    ) throws -> CGImage {
        guard canvasSize.width > 0, canvasSize.height > 0 else {
            throw makeError("标注画布尺寸无效。")
        }

        let width = baseImage.width
        let height = baseImage.height
        let colorSpace = baseImage.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw makeError("无法创建标注画布。")
        }

        let pixelRect = CGRect(x: 0, y: 0, width: width, height: height)
        context.interpolationQuality = .high
        context.draw(baseImage, in: pixelRect)

        let scaleX = CGFloat(width) / canvasSize.width
        let scaleY = CGFloat(height) / canvasSize.height

        try drawMosaics(
            items.filter { $0.tool == .mosaic },
            baseImage: baseImage,
            context: context,
            canvasSize: canvasSize,
            scaleX: scaleX,
            scaleY: scaleY
        )
        drawHighlights(
            items.filter { $0.tool == .highlight },
            context: context,
            canvasSize: canvasSize,
            scaleX: scaleX,
            scaleY: scaleY
        )

        context.saveGState()
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: scaleX, y: -scaleY)
        context.clip(to: CGRect(origin: .zero, size: canvasSize))
        for item in items where item.tool != .mosaic && item.tool != .highlight {
            drawVector(item, in: context)
        }
        context.restoreGState()

        guard let result = context.makeImage() else {
            throw makeError("无法生成标注图片。")
        }
        return result
    }

    private static func drawMosaics(
        _ items: [AnnotationItem],
        baseImage: CGImage,
        context: CGContext,
        canvasSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) throws {
        guard !items.isEmpty else { return }
        let ciContext = CIContext(options: [.cacheIntermediates: true])
        let input = CIImage(cgImage: baseImage)

        for item in items {
            guard case .path(let points) = item.geometry, points.count > 1 else { continue }
            let filterName = item.style.mosaicMode == .pixelate ? "CIPixellate" : "CIGaussianBlur"
            guard let filter = CIFilter(name: filterName) else { continue }
            filter.setValue(input, forKey: kCIInputImageKey)
            if item.style.mosaicMode == .pixelate {
                filter.setValue(item.style.mosaicStrength * max(scaleX, scaleY), forKey: kCIInputScaleKey)
                filter.setValue(CIVector(x: input.extent.midX, y: input.extent.midY), forKey: kCIInputCenterKey)
            } else {
                filter.setValue(item.style.mosaicStrength * max(scaleX, scaleY) * 0.55, forKey: kCIInputRadiusKey)
            }
            guard let output = filter.outputImage?.cropped(to: input.extent),
                  let processed = ciContext.createCGImage(output, from: input.extent) else {
                throw makeError("无法生成马赛克效果。")
            }

            context.saveGState()
            let path = CGMutablePath()
            let first = pixelPoint(points[0], canvasSize: canvasSize, scaleX: scaleX, scaleY: scaleY)
            path.move(to: first)
            for point in points.dropFirst() {
                path.addLine(to: pixelPoint(point, canvasSize: canvasSize, scaleX: scaleX, scaleY: scaleY))
            }
            context.addPath(path)
            context.setLineCap(.round)
            context.setLineJoin(.round)
            context.setLineWidth(item.style.lineWidth * (scaleX + scaleY) / 2)
            context.replacePathWithStrokedPath()
            context.clip()
            context.setAlpha(item.style.opacity)
            context.draw(processed, in: CGRect(x: 0, y: 0, width: baseImage.width, height: baseImage.height))
            context.restoreGState()
        }
    }

    private static func drawHighlights(
        _ items: [AnnotationItem],
        context: CGContext,
        canvasSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        guard !items.isEmpty else { return }
        let dimOpacity = items.map(\.style.highlightDimOpacity).max() ?? 0.55
        context.saveGState()
        let path = CGMutablePath()
        path.addRect(CGRect(x: 0, y: 0, width: canvasSize.width * scaleX, height: canvasSize.height * scaleY))
        for item in items {
            guard case .rect(let logicalRect) = item.geometry else { continue }
            let pixelRect = pixelRect(
                logicalRect.standardized,
                canvasSize: canvasSize,
                scaleX: scaleX,
                scaleY: scaleY
            )
            if item.style.highlightShape == .ellipse {
                path.addEllipse(in: pixelRect)
            } else {
                path.addRoundedRect(in: pixelRect, cornerWidth: 4 * scaleX, cornerHeight: 4 * scaleY)
            }
        }
        context.addPath(path)
        context.setFillColor(NSColor.black.withAlphaComponent(dimOpacity).cgColor)
        context.drawPath(using: .eoFill)
        context.restoreGState()
    }

    private static func drawVector(_ item: AnnotationItem, in context: CGContext) {
        let style = item.style
        let strokeColor = style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity)
        let fillColor = style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity * 0.22)

        context.saveGState()
        context.setLineCap(.round)
        context.setLineJoin(.round)
        context.setLineWidth(style.lineWidth)
        context.setStrokeColor(strokeColor.cgColor)
        context.setFillColor(fillColor.cgColor)
        applyLinePattern(style.linePattern, width: style.lineWidth, to: context)

        switch (item.tool, item.geometry) {
        case (.rectangle, .rect(let rect)):
            drawShape(path: CGPath(rect: rect.standardized, transform: nil), style: style, context: context)
        case (.ellipse, .rect(let rect)):
            drawShape(path: CGPath(ellipseIn: rect.standardized, transform: nil), style: style, context: context)
        case (.line, .line(let start, let end)):
            context.move(to: start)
            context.addLine(to: end)
            context.strokePath()
        case (.arrow, .line(let start, let end)):
            drawArrow(start: start, end: end, style: style, context: context)
        case (.pen, .path(let points)):
            drawSmoothPath(points, context: context)
        case (.text, .text(let frame, let value)):
            drawText(value, frame: frame, style: style, context: context)
        case (.sequence, .badge(let step)):
            drawStep(step, style: style, context: context)
        default:
            break
        }
        context.restoreGState()
    }

    private static func drawShape(path: CGPath, style: AnnotationStyle, context: CGContext) {
        context.addPath(path)
        switch style.fillMode {
        case .stroke:
            context.strokePath()
        case .fill:
            context.fillPath()
        case .strokeAndFill:
            context.drawPath(using: .fillStroke)
        }
    }

    private static func drawSmoothPath(_ points: [CGPoint], context: CGContext) {
        guard let first = points.first else { return }
        context.move(to: first)
        guard points.count > 2 else {
            if let last = points.last { context.addLine(to: last) }
            context.strokePath()
            return
        }
        for index in 1..<points.count {
            let previous = points[index - 1]
            let current = points[index]
            let midpoint = CGPoint(x: (previous.x + current.x) / 2, y: (previous.y + current.y) / 2)
            context.addQuadCurve(to: midpoint, control: previous)
        }
        if let last = points.last { context.addLine(to: last) }
        context.strokePath()
    }

    private static func drawArrow(
        start: CGPoint,
        end: CGPoint,
        style: AnnotationStyle,
        context: CGContext
    ) {
        context.move(to: start)
        context.addLine(to: end)
        context.strokePath()
        drawArrowHead(at: end, from: start, size: max(10, style.lineWidth * 4), context: context)
        if style.arrowHeads == .both {
            drawArrowHead(at: start, from: end, size: max(10, style.lineWidth * 4), context: context)
        }
    }

    private static func drawArrowHead(at tip: CGPoint, from tail: CGPoint, size: CGFloat, context: CGContext) {
        let angle = atan2(tip.y - tail.y, tip.x - tail.x)
        let spread = CGFloat.pi / 7
        let first = CGPoint(x: tip.x - cos(angle - spread) * size, y: tip.y - sin(angle - spread) * size)
        let second = CGPoint(x: tip.x - cos(angle + spread) * size, y: tip.y - sin(angle + spread) * size)
        context.move(to: first)
        context.addLine(to: tip)
        context.addLine(to: second)
        context.strokePath()
    }

    private static func drawText(
        _ value: String,
        frame: CGRect,
        style: AnnotationStyle,
        context: CGContext
    ) {
        if style.hasTextBackground {
            context.setFillColor(NSColor.black.withAlphaComponent(0.62 * style.opacity).cgColor)
            context.fill(frame.standardized)
        }
        let font = style.isBold
            ? NSFont.boldSystemFont(ofSize: style.fontSize)
            : NSFont.systemFont(ofSize: style.fontSize)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byWordWrapping
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity),
            .paragraphStyle: paragraph
        ]
        let attributed = NSAttributedString(string: value, attributes: attributes)
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        attributed.draw(with: frame.standardized.insetBy(dx: 3, dy: 2), options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawBadge(
        _ number: Int,
        frame: CGRect,
        style: AnnotationStyle,
        context: CGContext
    ) {
        let frame = frame.standardized
        context.setFillColor(style.color.nsColor.withAlphaComponent(style.color.alpha * style.opacity).cgColor)
        context.fillEllipse(in: frame)

        let fontSize = max(10, min(frame.width, frame.height) * 0.52)
        let font = NSFont.boldSystemFont(ofSize: fontSize)
        let value = "\(number)" as NSString
        let attributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.white.withAlphaComponent(style.opacity)
        ]
        let size = value.size(withAttributes: attributes)
        let textRect = CGRect(
            x: frame.midX - size.width / 2,
            y: frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        let graphicsContext = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        value.draw(in: textRect, withAttributes: attributes)
        NSGraphicsContext.restoreGraphicsState()
    }

    private static func drawStep(
        _ step: StepAnnotationGeometry,
        style: AnnotationStyle,
        context: CGContext
    ) {
        drawBadge(step.number, frame: step.badgeFrame, style: style, context: context)
        guard !step.text.isEmpty else { return }
        var labelStyle = style
        labelStyle.fontSize = max(10, min(step.badgeFrame.width, step.badgeFrame.height) * 0.52)
        labelStyle.hasTextBackground = false
        drawText(step.text, frame: step.labelFrame, style: labelStyle, context: context)
    }

    private static func applyLinePattern(
        _ pattern: AnnotationLinePattern,
        width: CGFloat,
        to context: CGContext
    ) {
        switch pattern {
        case .solid:
            context.setLineDash(phase: 0, lengths: [])
        case .dashed:
            context.setLineDash(phase: 0, lengths: [max(5, width * 2.5), max(3, width * 1.5)])
        case .dotted:
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [0.1, max(3, width * 2)])
        }
    }

    private static func pixelPoint(
        _ point: CGPoint,
        canvasSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGPoint {
        CGPoint(x: point.x * scaleX, y: (canvasSize.height - point.y) * scaleY)
    }

    private static func pixelRect(
        _ rect: CGRect,
        canvasSize: CGSize,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) -> CGRect {
        CGRect(
            x: rect.minX * scaleX,
            y: (canvasSize.height - rect.maxY) * scaleY,
            width: rect.width * scaleX,
            height: rect.height * scaleY
        )
    }

    private static func makeError(_ message: String) -> NSError {
        NSError(domain: "Brushot.AnnotationRenderer", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
