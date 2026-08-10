import AppKit
import XCTest
@testable import SnapInk

@MainActor
final class PinningTests: XCTestCase {
    func testHistoryDeduplicatesAndPersistsCanonicalPNG() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinHistoryStore(directoryURL: directory)
        let image = try makeImage(width: 32, height: 20, color: .systemRed)
        let firstDate = Date(timeIntervalSince1970: 100)
        let secondDate = Date(timeIntervalSince1970: 200)

        let first = try store.add(image, now: firstDate)
        let second = try store.add(image, now: secondDate)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].lastUsedAt, secondDate)
        XCTAssertNotNil(store.image(for: store.entries[0]))

        let reloaded = PinHistoryStore(directoryURL: directory)
        XCTAssertEqual(reloaded.entries.count, 1)
        XCTAssertEqual(reloaded.entries[0].contentHash, first.contentHash)
        XCTAssertEqual(reloaded.image(for: reloaded.entries[0])?.width, 32)
        XCTAssertEqual(reloaded.image(for: reloaded.entries[0])?.height, 20)
    }

    func testHistoryEnforcesLimitAndCanDeleteOrClear() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PinHistoryStore(directoryURL: directory, maxEntries: 2)
        _ = try store.add(try makeImage(width: 10, height: 10, color: .red), now: Date(timeIntervalSince1970: 1))
        _ = try store.add(try makeImage(width: 11, height: 10, color: .green), now: Date(timeIntervalSince1970: 2))
        _ = try store.add(try makeImage(width: 12, height: 10, color: .blue), now: Date(timeIntervalSince1970: 3))
        XCTAssertEqual(store.entries.count, 2)
        XCTAssertEqual(store.entries.map(\.pixelWidth), [12, 11])

        try store.delete(store.entries[0])
        XCTAssertEqual(store.entries.count, 1)
        try store.clear()
        XCTAssertTrue(store.entries.isEmpty)
    }

    func testPinWindowAppliesAppearanceDesktopBehaviorAndPixelMovement() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PinManager(historyStore: PinHistoryStore(directoryURL: directory))
        let image = try makeImage(width: 200, height: 100, color: .white)
        let controller = try manager.pin(image)
        let duplicateWindow = try manager.pin(image)
        defer {
            manager.closePin(id: controller.id)
            manager.closePin(id: duplicateWindow.id)
        }

        XCTAssertEqual(manager.historyStore.entries.count, 1)
        XCTAssertEqual(manager.pinWindows.count, 2)
        controller.setOpacity(0.5)
        XCTAssertEqual(controller.opacity, 0.5)
        XCTAssertEqual(controller.window?.alphaValue, 0.5)
        controller.setCornerRadius(16)
        XCTAssertEqual(controller.cornerRadius, 16)

        controller.setDesktopBehavior(.allDesktops)
        XCTAssertEqual(controller.desktopBehavior, .allDesktops)
        XCTAssertTrue(controller.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)
        controller.setDesktopBehavior(.currentDesktop)
        XCTAssertFalse(controller.window?.collectionBehavior.contains(.canJoinAllSpaces) == true)

        let original = try XCTUnwrap(controller.window?.frame.origin)
        controller.moveByPixels(dx: 1, dy: -1)
        let moved = try XCTUnwrap(controller.window?.frame.origin)
        XCTAssertEqual(moved.x, original.x + 1, accuracy: 0.001)
        XCTAssertEqual(moved.y, original.y - 1, accuracy: 0.001)

        manager.toggleAllPins()
        XCTAssertFalse(controller.window?.isVisible == true)
        XCTAssertEqual(manager.visibilityMenuTitle, "显示全部贴图")
        let newPin = try manager.pin(try makeImage(width: 40, height: 40, color: .black))
        defer { manager.closePin(id: newPin.id) }
        XCTAssertTrue(controller.window?.isVisible == true)
        XCTAssertTrue(newPin.window?.isVisible == true)
        XCTAssertEqual(manager.visibilityMenuTitle, "隐藏全部贴图")
    }

    func testScreenshotPinUsesLogicalSelectionSizeForRetinaImage() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PinManager(historyStore: PinHistoryStore(directoryURL: directory))
        let retinaImage = try makeImage(width: 340, height: 280, color: .white)

        let controller = try manager.pin(
            retinaImage,
            displaySize: CGSize(width: 170, height: 140)
        )
        defer { manager.closePin(id: controller.id) }

        let contentSize = try XCTUnwrap(controller.window?.contentView?.frame.size)
        XCTAssertEqual(contentSize.width, 170, accuracy: 0.001)
        XCTAssertEqual(contentSize.height, 140, accuracy: 0.001)
    }

    func testExtremeAndTinyPinImagesKeepTheirOriginalAspectRatio() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let manager = PinManager(historyStore: PinHistoryStore(directoryURL: directory))
        let dimensions = [(400, 30), (30, 400), (30, 30)]

        for (width, height) in dimensions {
            let image = try makeImage(width: width, height: height, color: .white)
            let controller = try manager.pin(image, recordHistory: false)
            defer { manager.closePin(id: controller.id) }
            let contentSize = try XCTUnwrap(controller.window?.contentView?.frame.size)

            XCTAssertEqual(
                contentSize.width / contentSize.height,
                CGFloat(width) / CGFloat(height),
                accuracy: 0.001
            )
            if width == height {
                XCTAssertEqual(contentSize, CGSize(width: 80, height: 80))
            }
        }
    }

    func testMismatchedPreferredSizeIsProjectedOntoImageAspectRatio() throws {
        let image = try makeImage(width: 400, height: 100, color: .white)

        let size = PinWindowController.displaySize(
            for: image,
            preferredSize: CGSize(width: 200, height: 200)
        )

        XCTAssertEqual(size.width / size.height, 4, accuracy: 0.001)
        XCTAssertEqual(size.width * size.height, 40_000, accuracy: 0.001)
    }

    func testPinDrawingUsesAspectFitAsLastLineOfDefense() throws {
        let destination = try XCTUnwrap(PinImageView.aspectFitRect(
            imageSize: CGSize(width: 400, height: 100),
            in: CGRect(x: 0, y: 0, width: 200, height: 200)
        ))

        XCTAssertEqual(destination, CGRect(x: 0, y: 75, width: 200, height: 50))
    }

    func testClipboardImagePins() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("SnapInk-PinningTests-\(UUID().uuidString)"))
        pasteboard.declareTypes([.png], owner: nil)
        let base = try makeImage(width: 80, height: 60, color: .white)
        guard pasteboard.setData(try PinImageCodec.pngData(from: base), forType: .png) else {
            throw XCTSkip("当前测试环境禁止访问 NSPasteboard")
        }
        let manager = PinManager(historyStore: PinHistoryStore(directoryURL: directory))
        let pin = try manager.pinClipboard(pasteboard)
        defer { manager.closePin(id: pin.id) }
        XCTAssertEqual(pin.image.width, 80)
        XCTAssertEqual(manager.historyStore.entries.count, 1)
    }

    func testSecondaryAnnotationProducesUpdatedFlattenedImage() throws {
        let base = try makeImage(width: 80, height: 60, color: .white)
        var annotated: CGImage?
        let editor = PinAnnotationEditorWindowController(image: base) { annotated = $0 } onCancel: {}
        let content = try XCTUnwrap(editor.window?.contentView)
        let canvas = try XCTUnwrap(descendants(of: content).compactMap { $0 as? AnnotationCanvasView }.first)
        _ = canvas.document.add(
            tool: .rectangle,
            geometry: .rect(CGRect(x: 5, y: 5, width: 30, height: 20)),
            style: .defaultStyle(for: .rectangle)
        )
        let save = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSButton }.first {
            $0.identifier?.rawValue == "saveAction"
        })
        save.performClick(nil)
        let result = try XCTUnwrap(annotated)
        XCTAssertEqual(result.width, base.width)
        XCTAssertEqual(result.height, base.height)
        XCTAssertNotEqual(try PinImageCodec.pngData(from: result), try PinImageCodec.pngData(from: base))
    }

    func testTallAnnotationImageUsesScrollableCanvasWithoutShrinkingItsWidth() throws {
        let base = try makeImage(width: 700, height: 4_200, color: .white)
        let editor = PinAnnotationEditorWindowController(
            image: base,
            title: "长截图标注",
            onFinish: { _ in },
            onCancel: {}
        )
        let content = try XCTUnwrap(editor.window?.contentView)
        let scrollView = try XCTUnwrap(descendants(of: content).compactMap { $0 as? NSScrollView }.first)
        let canvas = try XCTUnwrap(scrollView.documentView as? AnnotationCanvasView)

        XCTAssertEqual(editor.window?.title, "长截图标注")
        XCTAssertTrue(scrollView.hasVerticalScroller)
        XCTAssertGreaterThan(canvas.frame.height, scrollView.contentSize.height)
        XCTAssertGreaterThanOrEqual(canvas.frame.width, 690)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SnapInk-PinningTests-\(UUID().uuidString)", isDirectory: true)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews + view.subviews.flatMap(descendants(of:))
    }

    private func makeImage(width: Int, height: Int, color: NSColor) throws -> CGImage {
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
}
