import AppKit
import XCTest
@testable import SnapInk

final class AnnotationRendererTests: XCTestCase {
    func testRendererPreservesBasePixelDimensionsAtRetinaScale() throws {
        let base = try makeSolidImage(width: 200, height: 100, color: .white)
        let item = AnnotationItem(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 10, y: 10, width: 40, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )
        let result = try AnnotationRenderer.render(
            baseImage: base,
            canvasSize: CGSize(width: 100, height: 50),
            items: [item]
        )
        XCTAssertEqual(result.width, 200)
        XCTAssertEqual(result.height, 100)
    }

    func testHighlightDimsOutsideAndPreservesInside() throws {
        let base = try makeSolidImage(width: 100, height: 100, color: .white)
        var style = AnnotationStyle.defaultStyle(for: .highlight)
        style.highlightDimOpacity = 0.55
        let highlight = AnnotationItem(
            tool: .highlight,
            geometry: .rect(CGRect(x: 25, y: 25, width: 50, height: 50)),
            style: style
        )
        let result = try AnnotationRenderer.render(
            baseImage: base,
            canvasSize: CGSize(width: 100, height: 100),
            items: [highlight]
        )
        let center = try pixel(result, x: 50, y: 50)
        let corner = try pixel(result, x: 5, y: 5)
        XCTAssertGreaterThan(center.red, 245)
        XCTAssertLessThan(corner.red, 150)
        XCTAssertGreaterThan(corner.red, 90)
    }

    func testMosaicChangesOnlyStrokeMask() throws {
        let base = try makeCheckerboardImage(width: 120, height: 120)
        var style = AnnotationStyle.defaultStyle(for: .mosaic)
        style.lineWidth = 30
        style.mosaicStrength = 18
        let mosaic = AnnotationItem(
            tool: .mosaic,
            geometry: .path([CGPoint(x: 25, y: 60), CGPoint(x: 95, y: 60)]),
            style: style
        )
        let result = try AnnotationRenderer.render(
            baseImage: base,
            canvasSize: CGSize(width: 120, height: 120),
            items: [mosaic]
        )

        XCTAssertEqual(try pixel(base, x: 5, y: 5), try pixel(result, x: 5, y: 5))
        var changedPixels = 0
        for x in stride(from: 30, through: 90, by: 3) {
            if try pixel(base, x: x, y: 60) != pixel(result, x: x, y: 60) {
                changedPixels += 1
            }
        }
        XCTAssertGreaterThan(changedPixels, 0)
    }

    func testAllAnnotationKindsRenderTogether() throws {
        let base = try makeSolidImage(width: 320, height: 220, color: .white)
        let red = AnnotationStyle.defaultStyle(for: .rectangle)
        var fill = red
        fill.fillMode = .strokeAndFill
        let items: [AnnotationItem] = [
            AnnotationItem(tool: .rectangle, geometry: .rect(CGRect(x: 10, y: 10, width: 70, height: 40)), style: fill),
            AnnotationItem(tool: .ellipse, geometry: .rect(CGRect(x: 90, y: 10, width: 60, height: 40)), style: fill),
            AnnotationItem(tool: .line, geometry: .line(start: CGPoint(x: 10, y: 70), end: CGPoint(x: 120, y: 90)), style: red),
            AnnotationItem(tool: .arrow, geometry: .line(start: CGPoint(x: 10, y: 105), end: CGPoint(x: 120, y: 130)), style: red),
            AnnotationItem(tool: .pen, geometry: .path([CGPoint(x: 160, y: 20), CGPoint(x: 200, y: 50), CGPoint(x: 240, y: 20)]), style: red),
            AnnotationItem(tool: .text, geometry: .text(frame: CGRect(x: 160, y: 65, width: 140, height: 45), value: "SnapInk"), style: .defaultStyle(for: .text)),
            AnnotationItem(tool: .sequence, geometry: .badge(StepAnnotationGeometry(badgeFrame: CGRect(x: 160, y: 125, width: 30, height: 30), number: 1, labelFrame: CGRect(x: 198, y: 125, width: 105, height: 35), text: "第一步")), style: .defaultStyle(for: .sequence))
        ]
        let result = try AnnotationRenderer.render(
            baseImage: base,
            canvasSize: CGSize(width: 320, height: 220),
            items: items
        )
        XCTAssertEqual(result.width, 320)
        XCTAssertGreaterThan(try changedPixelCount(between: base, and: result), 100)
    }

    func testStepDescriptionRendersWithoutBackgroundInBadgeColor() throws {
        let base = try makeSolidImage(width: 240, height: 80, color: .white)
        var style = AnnotationStyle.defaultStyle(for: .sequence)
        style.color = RGBAColor(red: 0, green: 0.478, blue: 1)
        let step = AnnotationItem(
            tool: .sequence,
            geometry: .badge(StepAnnotationGeometry(
                badgeFrame: CGRect(x: 15, y: 20, width: 32, height: 32),
                number: 1,
                labelFrame: CGRect(x: 56, y: 18, width: 150, height: 40),
                text: "STEP TEXT"
            )),
            style: style
        )
        let result = try AnnotationRenderer.render(
            baseImage: base,
            canvasSize: CGSize(width: 240, height: 80),
            items: [step]
        )

        var coloredTextPixels = 0
        var untouchedBackgroundPixels = 0
        for y in 18..<58 {
            for x in 56..<206 {
                let value = try pixel(result, x: x, y: y)
                if Int(value.blue) > Int(value.red) + 20 { coloredTextPixels += 1 }
                if value.red > 250, value.green > 250, value.blue > 250 { untouchedBackgroundPixels += 1 }
            }
        }
        XCTAssertGreaterThan(coloredTextPixels, 20)
        XCTAssertGreaterThan(untouchedBackgroundPixels, 1_000, "步骤说明应保持透明背景")
    }

    private struct Pixel: Equatable {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
    }

    private func makeSolidImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func makeCheckerboardImage(width: Int, height: Int) throws -> CGImage {
        let context = try makeContext(width: width, height: height)
        for y in stride(from: 0, to: height, by: 4) {
            for x in stride(from: 0, to: width, by: 4) {
                let isWhite = ((x / 4) + (y / 4)).isMultiple(of: 2)
                context.setFillColor((isWhite ? NSColor.white : NSColor.black).cgColor)
                context.fill(CGRect(x: x, y: y, width: 4, height: 4))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func makeContext(width: Int, height: Int) throws -> CGContext {
        try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
    }

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Pixel {
        let width = image.width
        let height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        let offset = ((height - 1 - y) * width + x) * 4
        return Pixel(red: bytes[offset], green: bytes[offset + 1], blue: bytes[offset + 2], alpha: bytes[offset + 3])
    }

    private func changedPixelCount(between first: CGImage, and second: CGImage) throws -> Int {
        let firstBytes = try bitmapBytes(first)
        let secondBytes = try bitmapBytes(second)
        var count = 0
        for y in stride(from: 0, to: first.height, by: 2) {
            for x in stride(from: 0, to: first.width, by: 2) {
                let offset = (y * first.width + x) * 4
                if firstBytes[offset..<(offset + 4)] != secondBytes[offset..<(offset + 4)] {
                    count += 1
                }
            }
        }
        return count
    }

    private func bitmapBytes(_ image: CGImage) throws -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: image.width,
            height: image.height,
            bitsPerComponent: 8,
            bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return bytes
    }
}
