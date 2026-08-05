import AppKit
import XCTest
@testable import SnapInk

final class GIFEncoderTests: XCTestCase {
    func testEncodeProducesValidGIF() throws {
        let frames = [
            makeFrame(width: 40, height: 30, red: 1.0, green: 0.2, blue: 0.2),
            makeFrame(width: 40, height: 30, red: 0.2, green: 1.0, blue: 0.2),
            makeFrame(width: 40, height: 30, red: 0.2, green: 0.2, blue: 1.0)
        ]
        let data = try GIFEncoder.encode(frames: frames, options: .default)
        XCTAssertGreaterThan(data.count, 0)
        let magic = String(data: data.prefix(6), encoding: .ascii)
        XCTAssertTrue(magic == "GIF89a" || magic == "GIF87a", "GIF magic header expected, got \(magic ?? "nil")")
    }

    func testEmptyFramesThrow() {
        XCTAssertThrowsError(try GIFEncoder.encode(frames: [], options: .default)) { error in
            XCTAssertEqual(error as? GIFEncoderError, .noFrames)
        }
    }

    func testMaxWidthDownscalesOutput() throws {
        // A wide source frame should be downscaled; the encoded GIF is still
        // valid and noticeably smaller than an unscaled one.
        let wide = makeFrame(width: 1000, height: 200, red: 0.9, green: 0.5, blue: 0.1)
        let downscaled = try GIFEncoder.encode(
            frames: [wide],
            options: GIFEncodingOptions(fps: 10, maxWidth: 200, loopCount: 0)
        )
        let unscaled = try GIFEncoder.encode(
            frames: [wide],
            options: GIFEncodingOptions(fps: 10, maxWidth: 0, loopCount: 0)
        )
        XCTAssertLessThan(downscaled.count, unscaled.count)
        // Decoded first frame must respect the max width.
        if let source = CGImageSourceCreateWithData(downscaled as CFData, nil),
           let first = CGImageSourceCreateImageAtIndex(source, 0, nil) {
            XCTAssertLessThanOrEqual(first.width, 200)
        } else {
            XCTFail("could not decode GIF frames")
        }
    }

    func testEncodeWritesFile() throws {
        let frames = [
            makeFrame(width: 24, height: 24, red: 0.1, green: 0.2, blue: 0.3)
        ]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("snapink-gif-test.gif")
        _ = try GIFEncoder.encode(frames: frames, options: .default, to: url)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let data = try Data(contentsOf: url)
        XCTAssertGreaterThan(data.count, 0)
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Helpers

    private func makeFrame(
        width: Int,
        height: Int,
        red: CGFloat,
        green: CGFloat,
        blue: CGFloat
    ) -> CGImage {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(red: red, green: green, blue: blue, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()!
    }
}
