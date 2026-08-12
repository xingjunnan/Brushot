import AppKit
import XCTest
@testable import SnapInk

final class ScreenshotAppearanceTests: XCTestCase {
    func testPreferencesRoundTrip() {
        let defaults = UserDefaults(suiteName: "ScreenshotAppearanceTests.\(UUID().uuidString)")!
        ScreenshotAppearancePreferences.save(
            ScreenshotAppearanceConfiguration(
                addsShadow: true,
                shadowSize: 22,
                shadowColor: .systemRed,
                addsRoundedCorners: false,
                cornerRadius: 13
            ),
            defaults: defaults
        )

        var loaded = ScreenshotAppearancePreferences.load(defaults: defaults)
        XCTAssertTrue(loaded.addsShadow)
        XCTAssertEqual(loaded.shadowSize, 22)
        XCTAssertEqual(loaded.cornerRadius, 13)
        XCTAssertGreaterThan(loaded.shadowColor.redComponent, 0.8)
        XCTAssertFalse(loaded.addsRoundedCorners)

        ScreenshotAppearancePreferences.setAddsRoundedCorners(true, defaults: defaults)
        ScreenshotAppearancePreferences.setShadowSize(200, defaults: defaults)
        ScreenshotAppearancePreferences.setCornerRadius(-10, defaults: defaults)
        loaded = ScreenshotAppearancePreferences.load(defaults: defaults)
        XCTAssertTrue(loaded.addsShadow)
        XCTAssertTrue(loaded.addsRoundedCorners)
        XCTAssertEqual(loaded.shadowSize, ScreenshotAppearanceConfiguration.shadowSizeRange.upperBound)
        XCTAssertEqual(loaded.cornerRadius, ScreenshotAppearanceConfiguration.cornerRadiusRange.lowerBound)
    }

    func testDefaultRendererReturnsOriginalImage() throws {
        let image = try makeSolidImage(width: 80, height: 60, color: .systemBlue)

        let result = try ScreenshotAppearanceRenderer.render(image: image, configuration: .default)

        XCTAssertTrue(result === image)
    }

    func testRoundedCornersKeepSizeAndMakeCornersTransparent() throws {
        let image = try makeSolidImage(width: 120, height: 80, color: .white)

        let result = try ScreenshotAppearanceRenderer.render(
            image: image,
            configuration: ScreenshotAppearanceConfiguration(
                addsShadow: false,
                addsRoundedCorners: true,
                cornerRadius: 18
            )
        )

        XCTAssertEqual(result.width, image.width)
        XCTAssertEqual(result.height, image.height)
        XCTAssertLessThan(try pixel(result, x: 0, y: 0).alpha, 8)
        XCTAssertGreaterThan(try pixel(result, x: result.width / 2, y: result.height / 2).alpha, 248)
    }

    func testShadowAddsTransparentPadding() throws {
        let image = try makeSolidImage(width: 120, height: 80, color: .white)

        let result = try ScreenshotAppearanceRenderer.render(
            image: image,
            configuration: ScreenshotAppearanceConfiguration(
                addsShadow: true,
                shadowSize: 15,
                shadowColor: .black,
                addsRoundedCorners: false
            )
        )

        XCTAssertGreaterThan(result.width, image.width)
        XCTAssertGreaterThan(result.height, image.height)
        XCTAssertLessThan(try pixel(result, x: 0, y: 0).alpha, 8)
    }

    private struct Pixel {
        let red: UInt8
        let green: UInt8
        let blue: UInt8
        let alpha: UInt8
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

    private func pixel(_ image: CGImage, x: Int, y: Int) throws -> Pixel {
        var bytes = [UInt8](repeating: 0, count: 4)
        let context = try XCTUnwrap(CGContext(
            data: &bytes,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.draw(
            image,
            in: CGRect(x: -x, y: y - image.height + 1, width: image.width, height: image.height)
        )
        return Pixel(red: bytes[0], green: bytes[1], blue: bytes[2], alpha: bytes[3])
    }
}
