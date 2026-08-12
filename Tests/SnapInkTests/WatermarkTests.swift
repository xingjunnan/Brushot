import AppKit
import XCTest
@testable import SnapInk

final class WatermarkTests: XCTestCase {
    func testPreferencesDefaultToDisabledAndClampNumericValues() {
        let defaults = UserDefaults(suiteName: "WatermarkTests.\(UUID().uuidString)")!
        defaults.set(2.5, forKey: "watermark.opacity")
        defaults.set(0.1, forKey: "watermark.scale")
        defaults.set(200, forKey: "watermark.margin")

        let config = WatermarkPreferences.load(defaults: defaults)

        XCTAssertFalse(config.isEnabled)
        XCTAssertEqual(config.repeatMode, .single)
        XCTAssertEqual(config.opacity, 1)
        XCTAssertEqual(config.scale, 0.5)
        XCTAssertEqual(config.margin, 80)
        XCTAssertFalse(WatermarkPreferences.recordingEnabled(defaults: defaults))
    }

    func testRecordingWatermarkPreferenceRequiresRenderableContent() throws {
        let defaults = UserDefaults(suiteName: "WatermarkTests.\(UUID().uuidString)")!
        WatermarkPreferences.setRecordingEnabled(true, defaults: defaults)

        XCTAssertNil(WatermarkPreferences.currentRecordingConfiguration(defaults: defaults))

        var config = WatermarkConfiguration.default
        config.text = "SnapInk"
        config.isEnabled = false
        WatermarkPreferences.save(config, defaults: defaults)

        let recording = try XCTUnwrap(WatermarkPreferences.currentRecordingConfiguration(defaults: defaults))
        XCTAssertTrue(recording.isEnabled)
        XCTAssertEqual(recording.text, "SnapInk")
    }

    func testPreferencesPersistDiagonalTiledRepeatModeAndFallbackToSingle() {
        let defaults = UserDefaults(suiteName: "WatermarkTests.\(UUID().uuidString)")!
        var config = WatermarkConfiguration.default
        config.repeatMode = .diagonalTiled
        config.logoURL = URL(fileURLWithPath: "/tmp/internal-logo.png")
        config.logoDisplayName = "company-mark.png"

        WatermarkPreferences.save(config, defaults: defaults)

        let loaded = WatermarkPreferences.load(defaults: defaults)
        XCTAssertEqual(loaded.repeatMode, .diagonalTiled)
        XCTAssertEqual(loaded.logoDisplayName, "company-mark.png")

        defaults.set("unsupported", forKey: "watermark.repeatMode")

        XCTAssertEqual(WatermarkPreferences.load(defaults: defaults).repeatMode, .single)
    }

    func testPreferencesFallBackToLogoFileNameWhenDisplayNameIsMissing() {
        let defaults = UserDefaults(suiteName: "WatermarkTests.\(UUID().uuidString)")!
        defaults.set("/tmp/legacy-logo.png", forKey: "watermark.logoPath")

        XCTAssertEqual(WatermarkPreferences.load(defaults: defaults).logoDisplayName, "legacy-logo.png")
    }

    func testPlaceholderResolutionUsesCapturedDate() {
        let date = Date(timeIntervalSince1970: 1_735_689_845)
        let text = WatermarkRenderer.resolvePlaceholders(
            in: "SnapInk {date} {time} {datetime}",
            date: date,
            locale: Locale(identifier: "en_US_POSIX")
        )
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let datetime = formatter.string(from: date)
        formatter.dateFormat = "yyyy-MM-dd"
        let dateText = formatter.string(from: date)
        formatter.dateFormat = "HH:mm:ss"
        let timeText = formatter.string(from: date)

        XCTAssertEqual(text, "SnapInk \(dateText) \(timeText) \(datetime)")
    }

    func testRendererKeepsDimensionsAndDrawsWatermark() throws {
        let base = try makeSolidImage(width: 240, height: 120, color: .black)
        var config = WatermarkConfiguration.default
        config.isEnabled = true
        config.text = "SnapInk"
        config.position = .bottomRight
        config.opacity = 1
        config.textColor = .white

        let result = try WatermarkRenderer.render(
            image: base,
            configuration: config,
            context: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )

        XCTAssertEqual(result.width, base.width)
        XCTAssertEqual(result.height, base.height)
        XCTAssertGreaterThan(try changedPixelCount(between: base, and: result), 0)
    }

    func testDiagonalTiledRendererDrawsMoreThanSingleWatermark() throws {
        let base = try makeSolidImage(width: 480, height: 320, color: .black)
        var singleConfig = WatermarkConfiguration.default
        singleConfig.isEnabled = true
        singleConfig.text = "SnapInk"
        singleConfig.repeatMode = .single
        singleConfig.position = .bottomRight
        singleConfig.opacity = 1
        singleConfig.textColor = .white

        var tiledConfig = singleConfig
        tiledConfig.repeatMode = .diagonalTiled

        let single = try WatermarkRenderer.render(
            image: base,
            configuration: singleConfig,
            context: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )
        let tiled = try WatermarkRenderer.render(
            image: base,
            configuration: tiledConfig,
            context: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )

        XCTAssertEqual(tiled.width, base.width)
        XCTAssertEqual(tiled.height, base.height)
        XCTAssertGreaterThan(
            try changedPixelCount(between: base, and: tiled),
            try changedPixelCount(between: base, and: single)
        )
    }

    func testDiagonalTiledRendererHandlesSmallImages() throws {
        let base = try makeSolidImage(width: 48, height: 36, color: .black)
        var config = WatermarkConfiguration.default
        config.isEnabled = true
        config.text = "S"
        config.repeatMode = .diagonalTiled
        config.opacity = 1
        config.textColor = .white

        let result = try WatermarkRenderer.render(
            image: base,
            configuration: config,
            context: WatermarkContext(capturedAt: Date(timeIntervalSince1970: 0))
        )

        XCTAssertEqual(result.width, base.width)
        XCTAssertEqual(result.height, base.height)
    }

    func testImportLogoRejectsFilesLargerThanThreeMB() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-logo-\(UUID().uuidString).jpg")
        try Data(count: WatermarkPreferences.maxLogoFileSize + 1).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try WatermarkPreferences.importLogo(from: url)) { error in
            XCTAssertTrue(error.localizedDescription.contains("3MB"))
        }
    }

    func testImportLogoCreatesDownsampledSafeCopy() throws {
        let source = try temporaryImageFile(width: 2_000, height: 1_000)
        defer { try? FileManager.default.removeItem(at: source) }

        let imported = try WatermarkPreferences.importLogo(from: source)
        defer { WatermarkPreferences.removeLogoFileIfManaged(imported) }

        guard let image = CGImageSourceCreateWithURL(imported as CFURL, nil)
            .flatMap({ CGImageSourceCreateImageAtIndex($0, 0, nil) }) else {
            return XCTFail("Expected imported logo image")
        }
        XCTAssertLessThanOrEqual(max(image.width, image.height), WatermarkPreferences.maxImportedLogoPixelLength)
        XCTAssertTrue(imported.lastPathComponent.hasPrefix("logo-"))
        XCTAssertEqual(imported.pathExtension, "png")
    }

    func testImportLogoUsesUniqueSafeCopyPaths() throws {
        let firstSource = try temporaryImageFile(width: 400, height: 200)
        let secondSource = try temporaryImageFile(width: 320, height: 160)
        defer {
            try? FileManager.default.removeItem(at: firstSource)
            try? FileManager.default.removeItem(at: secondSource)
        }

        let first = try WatermarkPreferences.importLogo(from: firstSource)
        let second = try WatermarkPreferences.importLogo(from: secondSource)
        defer {
            WatermarkPreferences.removeLogoFileIfManaged(first)
            WatermarkPreferences.removeLogoFileIfManaged(second)
        }

        XCTAssertNotEqual(first, second)
    }

    func testImportLogoRejectsExtremelyTallScreenshots() throws {
        let source = try temporaryImageFile(width: 120, height: 900)
        defer { try? FileManager.default.removeItem(at: source) }

        XCTAssertThrowsError(try WatermarkPreferences.importLogo(from: source)) { error in
            XCTAssertTrue(error.localizedDescription.contains("比例"))
        }
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

    private func changedPixelCount(between first: CGImage, and second: CGImage) throws -> Int {
        let firstBytes = try bitmapBytes(first)
        let secondBytes = try bitmapBytes(second)
        var count = 0
        for index in stride(from: 0, to: min(firstBytes.count, secondBytes.count), by: 4) {
            if firstBytes[index..<(index + 4)] != secondBytes[index..<(index + 4)] {
                count += 1
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

    private func temporaryImageFile(width: Int, height: Int) throws -> URL {
        let image = try makeSolidImage(width: width, height: height, color: .white)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("watermark-logo-\(UUID().uuidString).jpg")
        let data = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(data, "public.jpeg" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, [
            kCGImageDestinationLossyCompressionQuality: 0.85
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))
        try (data as Data).write(to: url, options: .atomic)
        return url
    }
}
