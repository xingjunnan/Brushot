import AppKit
import XCTest
@testable import Brushot

final class OCRValueTests: XCTestCase {
    func testResultPreservesLineOrderAndNewlines() throws {
        let result = try OCRResult(lines: ["第一行", "Second line", "第三行"])

        XCTAssertEqual(result.lines, ["第一行", "Second line", "第三行"])
        XCTAssertEqual(result.text, "第一行\nSecond line\n第三行")
    }

    func testResultRejectsEmptyRecognition() {
        XCTAssertThrowsError(try OCRResult(lines: ["  ", "\n"])) { error in
            XCTAssertEqual(error as? OCRRecognitionError, .noText)
        }
    }

    func testPreferredLanguagesAreFilteredWithoutChangingPriority() {
        XCTAssertEqual(
            VisionTextRecognizer.supportedPreferredLanguages(
                from: ["en-US", "fr-FR", "zh-Hant", "zh-Hans"]
            ),
            ["zh-Hans", "zh-Hant", "en-US"]
        )
    }

    func testVisionRecognizesGeneratedChineseAndEnglishImage() async throws {
        let image = try await MainActor.run {
            try Self.makeTextImage(lines: ["Brushot OCR 2026", "中文文字识别"])
        }

        let result = try await VisionTextRecognizer().recognizeText(in: image)

        XCTAssertFalse(result.text.isEmpty)
        XCTAssertTrue(result.text.localizedCaseInsensitiveContains("Brushot"))
        XCTAssertGreaterThanOrEqual(result.lines.count, 2)
    }

    @MainActor
    private static func makeTextImage(lines: [String]) throws -> CGImage {
        let width = 900
        let height = 300
        let size = NSSize(width: width, height: height)
        let bitmap = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: width,
            pixelsHigh: height,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bytesPerRow: 0,
            bitsPerPixel: 0
        ))
        let graphicsContext = try XCTUnwrap(NSGraphicsContext(bitmapImageRep: bitmap))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphicsContext
        defer { NSGraphicsContext.restoreGraphicsState() }

        NSColor.white.setFill()
        NSRect(origin: .zero, size: size).fill()
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineSpacing = 18
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 58, weight: .medium),
            .foregroundColor: NSColor.black,
            .paragraphStyle: paragraphStyle
        ]
        (lines.joined(separator: "\n") as NSString).draw(
            in: NSRect(x: 40, y: 35, width: 820, height: 230),
            withAttributes: attributes
        )

        graphicsContext.flushGraphics()
        return try XCTUnwrap(bitmap.cgImage)
    }
}

@MainActor
final class OCRInteractionTests: XCTestCase {
    func testResultWindowCopiesEditedPlainText() throws {
        let controller = OCRResultWindowController(
            text: "原始文本",
            translationProvider: .unavailable
        )
        controller.text = "编辑后的第一行\nEdited second line"
        let pasteboard = NSPasteboard(name: .init("BrushotTests.OCR.\(UUID().uuidString)"))

        XCTAssertTrue(controller.copyText(to: pasteboard))
        XCTAssertEqual(
            pasteboard.string(forType: .string),
            "编辑后的第一行\nEdited second line"
        )
        XCTAssertTrue(pasteboard.types?.contains(.string) == true)
        XCTAssertFalse(pasteboard.types?.contains(.png) == true)
        XCTAssertFalse(pasteboard.types?.contains(.tiff) == true)
    }

    func testUnavailableTranslationKeepsSingleEditorAndHidesActions() {
        let controller = OCRResultWindowController(
            text: "Hello",
            translationProvider: .unavailable
        )
        let views = descendants(of: controller.window!.contentView!)

        XCTAssertNil(views.first { $0.identifier?.rawValue == "translateOCRAction" })
        XCTAssertNil(views.first { $0.identifier?.rawValue == "translatedText" })
        XCTAssertEqual(
            views.compactMap { $0 as? NSButton }
                .first { $0.identifier?.rawValue == "copyOCRAction" }?.title,
            "复制"
        )
    }

    func testTranslationUsesEditedTextAndCopiesTranslatedPlainText() async throws {
        var receivedText: String?
        let requestReceived = expectation(description: "translation requested")
        let controller = OCRResultWindowController(
            text: "Original",
            translationProvider: .custom { text in
                receivedText = text
                requestReceived.fulfill()
                return "你好，世界"
            }
        )
        controller.text = "Hello, world"
        controller.window?.contentView?.layoutSubtreeIfNeeded()

        let contentView = controller.window!.contentView!
        let editorScrollViews = descendants(of: contentView)
            .compactMap { $0 as? NSScrollView }
        XCTAssertEqual(editorScrollViews.count, 2)
        XCTAssertTrue(editorScrollViews.allSatisfy { $0.frame.width > 240 && $0.frame.height > 200 })
        let editorFrames = editorScrollViews.map { $0.convert($0.bounds, to: contentView) }
        XCTAssertEqual(editorFrames[0].minY, editorFrames[1].minY, accuracy: 0.5)
        XCTAssertNotEqual(editorFrames[0].minX, editorFrames[1].minX)
        XCTAssertEqual(contentView.frame.size, CGSize(width: 640, height: 360))

        try button(identifier: "translateOCRAction", in: controller).performClick(nil)
        await fulfillment(of: [requestReceived], timeout: 1)
        await Task.yield()

        XCTAssertEqual(receivedText, "Hello, world")
        XCTAssertEqual(controller.translatedText, "你好，世界")
        let pasteboard = NSPasteboard(name: .init("BrushotTests.OCRTranslation.\(UUID().uuidString)"))
        XCTAssertTrue(controller.copyTranslatedText(to: pasteboard))
        XCTAssertEqual(pasteboard.string(forType: .string), "你好，世界")
        XCTAssertTrue(
            try button(identifier: "copyTranslationAction", in: controller).isEnabled
        )
    }

    func testTranslationPreventsDuplicateSubmissionAndDiscardsStaleResult() async throws {
        var requestCount = 0
        let requestStarted = expectation(description: "translation started")
        let controller = OCRResultWindowController(
            text: "First text",
            translationProvider: .custom { _ in
                requestCount += 1
                requestStarted.fulfill()
                try await Task.sleep(for: .milliseconds(100))
                return "过期译文"
            }
        )
        let translateButton = try button(identifier: "translateOCRAction", in: controller)

        translateButton.performClick(nil)
        translateButton.performClick(nil)
        await fulfillment(of: [requestStarted], timeout: 1)
        XCTAssertEqual(requestCount, 1)
        XCTAssertFalse(translateButton.isEnabled)

        controller.text = "Second text"
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(controller.translatedText, "")
        XCTAssertTrue(translateButton.isEnabled)
        XCTAssertEqual(translateButton.title, "翻译成中文")
    }

    func testEmptySourceDoesNotRequestTranslation() throws {
        var requestCount = 0
        let controller = OCRResultWindowController(
            text: " \n ",
            translationProvider: .custom { _ in
                requestCount += 1
                return "不应生成"
            }
        )

        try button(identifier: "translateOCRAction", in: controller).performClick(nil)

        XCTAssertEqual(requestCount, 0)
        XCTAssertEqual(controller.translatedText, "")
    }

    func testToolbarOCRSubmitsOnlyOnceAndDisablesActionsWhileBusy() throws {
        let toolbar = AnnotationToolbarView(frame: CGRect(x: 0, y: 0, width: 650, height: 82))
        let buttons = descendants(of: toolbar).compactMap { $0 as? NSButton }
        let ocrButton = try XCTUnwrap(buttons.first { $0.identifier?.rawValue == "ocrAction" })
        var requests = 0
        toolbar.onOCR = { requests += 1 }

        ocrButton.performClick(nil)
        XCTAssertEqual(requests, 1)

        toolbar.setBusy(true, message: "正在识别文字…")
        XCTAssertFalse(ocrButton.isEnabled)
        let enabledActionButtons = buttons.filter {
            ["ocrAction"].contains($0.identifier?.rawValue ?? "") && $0.isEnabled
        }
        XCTAssertTrue(enabledActionButtons.isEmpty)
        ocrButton.performClick(nil)
        XCTAssertEqual(requests, 1)
    }

    func testNormalSelectionRequestsCurrentGlobalRegionOnce() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        let window = NSWindow(
            contentRect: CGRect(x: 120, y: 80, width: 400, height: 300),
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        window.contentView = overlay
        select(in: overlay, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 180))
        var sources: [OCRSource] = []
        overlay.onOCRRequested = { sources.append($0) }

        let button = try ocrButton(in: overlay)
        button.performClick(nil)
        button.performClick(nil)

        XCTAssertEqual(sources.count, 1)
        guard case .globalRect(let rect) = try XCTUnwrap(sources.first) else {
            return XCTFail("Expected current global selection")
        }
        XCTAssertEqual(rect.size, CGSize(width: 150, height: 130))
    }

    func testAnnotationOCRUsesFrozenOriginalInsteadOfRenderedAnnotations() throws {
        let overlay = SelectionOverlayView(frame: CGRect(x: 0, y: 0, width: 400, height: 300))
        select(in: overlay, from: CGPoint(x: 50, y: 50), to: CGPoint(x: 200, y: 180))
        overlay.enterAnnotationEditing(
            baseImage: try makeSolidImage(width: 400, height: 300, color: .white),
            initialTool: .rectangle
        )
        let canvas = try XCTUnwrap(overlay.subviews.compactMap { $0 as? AnnotationCanvasView }.first)
        var style = AnnotationStyle.defaultStyle(for: .rectangle)
        style.fillMode = .fill
        _ = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 55, y: 125, width: 140, height: 120)),
            style: style
        )
        let renderedImage = try canvas.renderedImage()
        var source: OCRSource?
        overlay.onOCRRequested = { source = $0 }

        try ocrButton(in: overlay).performClick(nil)

        guard case .image(let originalImage) = try XCTUnwrap(source) else {
            return XCTFail("Expected frozen original image")
        }
        XCTAssertEqual(originalImage.width, 150)
        XCTAssertEqual(originalImage.height, 130)
        XCTAssertTrue(try pixelIsWhite(originalImage, at: CGPoint(x: 75, y: 65)))
        XCTAssertFalse(try pixelIsWhite(renderedImage, at: CGPoint(x: 75, y: 65)))
    }

    private func select(in overlay: SelectionOverlayView, from start: CGPoint, to end: CGPoint) {
        overlay.mouseDown(with: mouseEvent(type: .leftMouseDown, at: start))
        overlay.mouseDragged(with: mouseEvent(type: .leftMouseDragged, at: end))
        overlay.mouseUp(with: mouseEvent(type: .leftMouseUp, at: end))
    }

    private func ocrButton(in view: NSView) throws -> NSButton {
        try XCTUnwrap(descendants(of: view).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "ocrAction"
        })
    }

    private func button(
        identifier: String,
        in controller: OCRResultWindowController
    ) throws -> NSButton {
        let contentView = try XCTUnwrap(controller.window?.contentView)
        return try XCTUnwrap(descendants(of: contentView).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == identifier
        })
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func mouseEvent(type: NSEvent.EventType, at point: CGPoint) -> NSEvent {
        NSEvent.mouseEvent(
            with: type,
            location: point,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            eventNumber: 1,
            clickCount: 1,
            pressure: 1
        )!
    }

    private func makeSolidImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.setFillColor(color.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    private func pixelIsWhite(_ image: CGImage, at point: CGPoint) throws -> Bool {
        var pixel = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &pixel,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.interpolationQuality = .none
        context.translateBy(x: -point.x, y: -point.y)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return pixel[0] > 245 && pixel[1] > 245 && pixel[2] > 245
    }
}
