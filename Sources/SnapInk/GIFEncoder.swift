import CoreGraphics
import Foundation
import ImageIO

/// Options for encoding a sequence of captured frames into an animated GIF.
struct GIFEncodingOptions {
    /// Frames per second used to compute each frame's delay.
    var fps: Double = 15
    /// Maximum output width in pixels; wider frames are downscaled to keep
    /// the file size manageable. 0 means no scaling.
    var maxWidth: Int = 720
    /// GIF loop count. 0 loops forever.
    var loopCount: Int = 0

    static let `default` = GIFEncodingOptions()
}

enum GIFEncoderError: LocalizedError, Equatable {
    case noFrames
    case destinationCreationFailed
    case finalizationFailed

    var errorDescription: String? {
        switch self {
        case .noFrames:
            "没有可编码的画面。"
        case .destinationCreationFailed:
            "无法创建 GIF 文件。"
        case .finalizationFailed:
            "GIF 编码失败。"
        }
    }
}

/// Encodes a sequence of `CGImage` frames into an animated GIF `Data`.
/// Built on ImageIO's `CGImageDestination`; per-frame delays are derived from
/// the requested fps, and frames wider than `maxWidth` are downscaled. ImageIO
/// performs 256-color palette quantization per frame.
enum GIFEncoder {
    static func encode(
        frames: [CGImage],
        options: GIFEncodingOptions = .default
    ) throws -> Data {
        guard !frames.isEmpty else { throw GIFEncoderError.noFrames }
        let capacity = frames.count
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            buffer,
            "com.compuserve.gif" as CFString,
            capacity,
            nil
        ) else {
            throw GIFEncoderError.destinationCreationFailed
        }

        // Global GIF properties: infinite loop (unless overridden).
        let globalProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: options.loopCount]
        ]
        CGImageDestinationSetProperties(destination, globalProperties as CFDictionary)

        let delay = 1.0 / options.fps
        let frameProperties: [CFString: Any] = [
            kCGImagePropertyGIFDictionary: [
                kCGImagePropertyGIFUnclampedDelayTime: delay
            ]
        ]

        for frame in frames {
            let prepared = prepareFrame(frame, maxWidth: options.maxWidth)
            CGImageDestinationAddImage(destination, prepared, frameProperties as CFDictionary)
        }

        guard CGImageDestinationFinalize(destination) else {
            throw GIFEncoderError.finalizationFailed
        }
        return buffer as Data
    }

    /// Writes a GIF file to `url`, returning the written data for convenience.
    static func encode(
        frames: [CGImage],
        options: GIFEncodingOptions = .default,
        to url: URL
    ) throws -> Data {
        let data = try encode(frames: frames, options: options)
        try data.write(to: url)
        return data
    }

    /// Downscale to `maxWidth` (preserving aspect ratio) so the output stays
    /// small. GIF has no inter-frame compression, so resolution is the main
    /// lever on file size.
    private static func prepareFrame(_ image: CGImage, maxWidth: Int) -> CGImage {
        guard maxWidth > 0, image.width > maxWidth else { return image }
        let scale = CGFloat(maxWidth) / CGFloat(image.width)
        let height = max(1, Int((CGFloat(image.height) * scale).rounded()))
        let cs = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: maxWidth,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            return image
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: maxWidth, height: height))
        return context.makeImage() ?? image
    }
}
