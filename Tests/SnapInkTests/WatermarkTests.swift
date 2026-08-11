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
        XCTAssertEqual(config.opacity, 1)
        XCTAssertEqual(config.scale, 0.5)
        XCTAssertEqual(config.margin, 80)
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
}
