import AppKit
import XCTest
@testable import SnapInk

final class LongCaptureTests: XCTestCase {
    func testStitcherJoinsOverlappingFramesLosslessly() throws {
        let source = try patternedImage(width: 180, height: 900)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 180, height: 420)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 250, width: 180, height: 420)))
        let third = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 480, width: 180, height: 420)))
        let stitcher = try LongCaptureStitcher(firstFrame: first)

        XCTAssertEqual(
            try stitcher.append(second),
            .appended(newPixelRows: 250, totalPixelHeight: 670)
        )
        XCTAssertEqual(
            try stitcher.append(third),
            .appended(newPixelRows: 230, totalPixelHeight: 900)
        )

        let result = try stitcher.renderedImage()
        XCTAssertEqual(result.width, source.width)
        XCTAssertEqual(result.height, source.height)
        XCTAssertEqual(try rgbaData(result), try rgbaData(source))
    }

    func testDuplicateFrameDoesNotIncreaseHeight() throws {
        let frame = try patternedImage(width: 160, height: 360)
        let stitcher = try LongCaptureStitcher(firstFrame: frame)

        XCTAssertEqual(try stitcher.append(frame), .duplicate)
        XCTAssertEqual(stitcher.frameCount, 1)
        XCTAssertEqual(stitcher.pixelHeight, 360)
    }

    func testUnrelatedOrWrongSizedFrameIsRejected() throws {
        let first = try patternedImage(width: 160, height: 360, seed: 1)
        let unrelated = try patternedImage(width: 160, height: 360, seed: 99)
        let wrongSize = try patternedImage(width: 150, height: 360)
        let stitcher = try LongCaptureStitcher(firstFrame: first)

        XCTAssertThrowsError(try stitcher.append(unrelated)) {
            XCTAssertEqual($0 as? LongCaptureStitchError, .noReliableOverlap)
        }
        XCTAssertThrowsError(try stitcher.append(wrongSize)) {
            XCTAssertEqual($0 as? LongCaptureStitchError, .inconsistentFrameSize)
        }
    }

    func testContinuousSmallScrollStepsCaptureEveryBlockAndFeedLivePreview() throws {
        let frameHeight = 360
        let step = 45
        let frameCount = 11
        let sourceHeight = frameHeight + step * (frameCount - 1)
        let source = try patternedImage(width: 170, height: sourceHeight)
        let first = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: 170,
            height: frameHeight
        )))
        let stitcher = try LongCaptureStitcher(firstFrame: first)

        for index in 1..<frameCount {
            let frame = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0,
                y: index * step,
                width: 170,
                height: frameHeight
            )))
            XCTAssertEqual(
                try stitcher.append(frame),
                .appended(
                    newPixelRows: step,
                    totalPixelHeight: frameHeight + index * step
                )
            )
        }

        let previewSegments = stitcher.previewSegmentImages
        XCTAssertEqual(previewSegments.count, frameCount)
        XCTAssertEqual(previewSegments.first?.height, frameHeight)
        XCTAssertTrue(previewSegments.dropFirst().allSatisfy { $0.height == step })
        XCTAssertEqual(previewSegments.reduce(0) { $0 + $1.height }, sourceHeight)
        XCTAssertEqual(try rgbaData(stitcher.renderedImage()), try rgbaData(source))
        XCTAssertLessThanOrEqual(LongCaptureSessionController.minimumCaptureInterval, 0.08)
        XCTAssertGreaterThan(
            LongCaptureSessionController.scrollActivityTail,
            LongCaptureSessionController.minimumCaptureInterval
        )
    }

    func testFastScrollCanStillJoinWithOnlyTenPercentOverlap() throws {
        let frameHeight = 420
        let displacement = 378
        let source = try patternedImage(width: 180, height: frameHeight + displacement)
        let first = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: 180,
            height: frameHeight
        )))
        let second = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: displacement,
            width: 180,
            height: frameHeight
        )))
        let stitcher = try LongCaptureStitcher(firstFrame: first)

        XCTAssertEqual(
            try stitcher.append(second),
            .appended(
                newPixelRows: displacement,
                totalPixelHeight: frameHeight + displacement
            )
        )
        XCTAssertEqual(try rgbaData(stitcher.renderedImage()), try rgbaData(source))
    }

    func testRepeatedListRowsDoNotProduceDuplicatedContent() throws {
        let frameHeight = 480
        let steps = [132, 139, 147, 154]
        let sourceHeight = frameHeight + steps.reduce(0, +)
        let source = try repetitiveListImage(width: 220, height: sourceHeight)
        let first = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: 220,
            height: frameHeight
        )))
        let stitcher = try LongCaptureStitcher(firstFrame: first)

        var offset = 0
        for step in steps {
            offset += step
            let frame = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0,
                y: offset,
                width: 220,
                height: frameHeight
            )))
            XCTAssertEqual(
                try stitcher.append(frame),
                .appended(newPixelRows: step, totalPixelHeight: frameHeight + offset)
            )
        }

        XCTAssertEqual(stitcher.pixelHeight, sourceHeight)
        XCTAssertEqual(try rgbaData(stitcher.renderedImage()), try rgbaData(source))
    }

    func testFixedBottomBarIsKeptOnlyOnceAcrossManySmallScrolls() throws {
        let width = 260
        let contentHeight = 460
        let footerHeight = 44
        let frameHeight = contentHeight + footerHeight
        let steps = (0..<30).map { 24 + ($0 % 5) * 3 }
        let finalOffset = steps.reduce(0, +)
        let source = try patternedImage(width: width, height: contentHeight + finalOffset)
        let footer = try patternedImage(width: width, height: footerHeight, seed: 101)
        let firstContent = try XCTUnwrap(source.cropping(to: CGRect(
            x: 0,
            y: 0,
            width: width,
            height: contentHeight
        )))
        let first = try verticalImage([firstContent, footer])
        let stitcher = try LongCaptureStitcher(firstFrame: first)
        var offset = 0

        for step in steps {
            offset += step
            let content = try XCTUnwrap(source.cropping(to: CGRect(
                x: 0,
                y: offset,
                width: width,
                height: contentHeight
            )))
            let frame = try verticalImage([content, footer])
            XCTAssertEqual(
                try stitcher.append(frame),
                .appended(newPixelRows: step, totalPixelHeight: frameHeight + offset)
            )
        }

        let expected = try verticalImage([source, footer])
        XCTAssertEqual(stitcher.pixelHeight, frameHeight + finalOffset)
        XCTAssertEqual(try rgbaData(stitcher.renderedImage()), try rgbaData(expected))
    }

    @MainActor
    func testFinalPreviewOffersOCRAndDoesNotOfferPinning() throws {
        let image = try patternedImage(width: 180, height: 720)
        var receivedSize: CGSize?
        var completionCount = 0
        let preview = LongCapturePreviewWindowController(
            image: image,
            logicalWidth: 180,
            onOCR: { receivedImage, completion in
                receivedSize = CGSize(width: receivedImage.width, height: receivedImage.height)
                completion()
                completionCount += 1
            },
            onDismiss: {}
        )
        let content = try XCTUnwrap(preview.window?.contentView)
        let buttons = allSubviews(of: content).compactMap { $0 as? NSButton }

        XCTAssertFalse(buttons.contains { $0.title == "贴图" })
        let ocr = try XCTUnwrap(buttons.first { $0.title == "OCR 文字识别" })
        ocr.performClick(nil)

        XCTAssertEqual(receivedSize, CGSize(width: 180, height: 720))
        XCTAssertEqual(completionCount, 1)
        XCTAssertTrue(ocr.isEnabled)
        XCTAssertEqual(ocr.title, "OCR 文字识别")
        preview.close()
    }

    func testLiveBorderIsDrawnOutsideCapturedSelection() {
        let selection = CGRect(x: 120, y: 80, width: 640, height: 360)
        let border = LongCaptureSessionController.borderFrame(for: selection)

        XCTAssertEqual(border.minX, selection.minX - 3)
        XCTAssertEqual(border.minY, selection.minY - 3)
        XCTAssertEqual(border.maxX, selection.maxX + 3)
        XCTAssertEqual(border.maxY, selection.maxY + 3)
        XCTAssertEqual(border.insetBy(dx: 3, dy: 3), selection)
    }

    @MainActor
    func testLiveSessionShowsPreviewAndUpdatesItAfterScroll() async throws {
        let source = try patternedImage(width: 300, height: 405)
        let first = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 0, width: 300, height: 360)))
        let second = try XCTUnwrap(source.cropping(to: CGRect(x: 0, y: 45, width: 300, height: 360)))
        let selection = CGRect(x: 100, y: 100, width: 300, height: 360)
        var captureCount = 0
        var cancelCount = 0
        let session = try LongCaptureSessionController(
            selectionRect: selection,
            firstFrame: first,
            captureFrame: {
                captureCount += 1
                return second
            },
            onFinish: { _, _ in },
            onCancel: { cancelCount += 1 },
            onError: { XCTFail("Unexpected long-capture error: \($0)") }
        )

        session.start()
        XCTAssertEqual(session.visibleOverlayWindowCount, 3)
        XCTAssertEqual(session.instructionText, LongCaptureSessionController.instruction)
        XCTAssertEqual(session.livePreviewHeightText, "360 px")
        XCTAssertEqual(session.livePreviewSegmentCount, 1)
        XCTAssertFalse(session.livePreviewWindowFrame.intersects(selection))

        session.receiveScroll(
            deltaX: 0,
            deltaY: -80,
            mouseLocation: CGPoint(x: selection.midX, y: selection.midY)
        )
        try await Task.sleep(for: .milliseconds(450))

        XCTAssertGreaterThanOrEqual(captureCount, 1)
        XCTAssertEqual(session.livePreviewHeightText, "405 px")
        XCTAssertEqual(session.livePreviewSegmentCount, 2)
        XCTAssertEqual(
            session.instructionText,
            "在框内向下滚动，结束后点击“完成”",
            "状态区应保持为固定帮助，不猜测是否已经到底"
        )
        session.cancel()
        XCTAssertEqual(cancelCount, 1)
        XCTAssertEqual(session.visibleOverlayWindowCount, 0)
    }

    private func patternedImage(width: Int, height: Int, seed: Int = 7) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        for y in 0..<height {
            let value = (y * 37 + seed * 53) % 255
            context.setFillColor(NSColor(
                calibratedRed: CGFloat(value) / 255,
                green: CGFloat((value * 5 + y / 3) % 255) / 255,
                blue: CGFloat((value * 11 + y) % 255) / 255,
                alpha: 1
            ).cgColor)
            context.fill(CGRect(x: 0, y: y, width: width, height: 1))
            for x in stride(from: 0, to: width, by: 17) {
                let accent = (x * 19 + y * 23 + seed * 71) % 255
                context.setFillColor(NSColor(
                    calibratedRed: CGFloat((accent * 3) % 255) / 255,
                    green: CGFloat((accent * 7 + x) % 255) / 255,
                    blue: CGFloat((accent * 13 + y) % 255) / 255,
                    alpha: 1
                ).cgColor)
                context.fill(CGRect(x: x, y: y, width: min(5, width - x), height: 1))
            }
            if y % 29 == 0 {
                context.setFillColor(NSColor.white.cgColor)
                context.fill(CGRect(x: (y * 13 + seed) % max(1, width - 20), y: y, width: 20, height: 3))
            }
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func repetitiveListImage(width: Int, height: Int) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ))
        let rowHeight = 28
        for rowTop in stride(from: 0, to: height, by: rowHeight) {
            let row = rowTop / rowHeight
            let background: NSColor = row.isMultiple(of: 2)
                ? NSColor(calibratedWhite: 0.13, alpha: 1)
                : NSColor(calibratedWhite: 0.17, alpha: 1)
            context.setFillColor(background.cgColor)
            context.fill(CGRect(x: 0, y: rowTop, width: width, height: rowHeight))
            context.setFillColor(NSColor(calibratedWhite: 0.28, alpha: 1).cgColor)
            context.fill(CGRect(x: 0, y: rowTop, width: width, height: 1))

            // Most of every row repeats like a Finder/table list. These small
            // row-specific markers are the equivalent of changing filenames
            // and dates and must keep the matcher on the true displacement.
            let markerX = 18 + (row * 37) % max(1, width - 72)
            let markerWidth = 8 + (row * 11) % 31
            context.setFillColor(NSColor(
                calibratedRed: CGFloat((row * 29) % 255) / 255,
                green: CGFloat((row * 47 + 80) % 255) / 255,
                blue: CGFloat((row * 71 + 160) % 255) / 255,
                alpha: 1
            ).cgColor)
            context.fill(CGRect(
                x: markerX,
                y: rowTop + 9,
                width: min(markerWidth, width - markerX),
                height: 7
            ))
        }
        return try XCTUnwrap(context.makeImage())
    }

    private func fixedChromeListImage(
        width: Int,
        height: Int,
        headerHeight: Int,
        contentOffset: Int
    ) throws -> CGImage {
        let bytesPerRow = width * 4
        let sidebarWidth = 48
        var data = Data(count: bytesPerRow * height)
        data.withUnsafeMutableBytes { rawBytes in
            let bytes = rawBytes.bindMemory(to: UInt8.self)
            for y in 0..<height {
                for x in 0..<width {
                    let offset = y * bytesPerRow + x * 4
                    let red: Int
                    let green: Int
                    let blue: Int
                    if y < headerHeight {
                        red = 35 + (x / 18) % 3
                        green = 38 + (x / 18) % 3
                        blue = 44 + (x / 18) % 3
                    } else if x < sidebarWidth {
                        red = 29
                        green = 32 + (y / 24) % 2
                        blue = 38
                    } else {
                        let documentY = contentOffset + y - headerHeight
                        let row = documentY / 30
                        let withinRow = documentY % 30
                        let alternating = row.isMultiple(of: 2) ? 31 : 39
                        if withinRow == 0 {
                            red = 62
                            green = 65
                            blue = 72
                        } else if withinRow >= 9,
                                  withinRow <= 17,
                                  x >= 62 + (row * 17) % 46,
                                  x < 112 + (row * 29) % 74 {
                            red = 90 + (row * 31) % 130
                            green = 105 + (row * 17) % 110
                            blue = 120 + (row * 11) % 100
                        } else {
                            red = alternating
                            green = alternating + 2
                            blue = alternating + 5
                        }
                    }
                    bytes[offset] = UInt8(red)
                    bytes[offset + 1] = UInt8(green)
                    bytes[offset + 2] = UInt8(blue)
                    bytes[offset + 3] = 255
                }
            }
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func verticalImage(_ images: [CGImage]) throws -> CGImage {
        let width = try XCTUnwrap(images.first?.width)
        XCTAssertTrue(images.allSatisfy { $0.width == width })
        let height = images.reduce(0) { $0 + $1.height }
        let bytesPerRow = width * 4
        var data = Data()
        data.reserveCapacity(bytesPerRow * height)
        for image in images {
            data.append(try rgbaData(image))
        }
        let provider = try XCTUnwrap(CGDataProvider(data: data as CFData))
        return try XCTUnwrap(CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                    | CGBitmapInfo.byteOrder32Big.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        ))
    }

    private func rgbaData(_ image: CGImage) throws -> Data {
        let bytesPerRow = image.width * 4
        var data = Data(count: bytesPerRow * image.height)
        let created = data.withUnsafeMutableBytes { bytes -> Bool in
            guard let base = bytes.baseAddress,
                  let context = CGContext(
                    data: base,
                    width: image.width,
                    height: image.height,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
            return true
        }
        return try XCTUnwrap(created ? data : nil)
    }

    @MainActor
    private func allSubviews(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(allSubviews)
    }
}
