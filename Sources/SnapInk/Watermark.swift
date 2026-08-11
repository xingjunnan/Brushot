import AppKit
import CoreGraphics
import Foundation
import ImageIO

struct WatermarkConfiguration: Equatable {
    enum Position: String, CaseIterable {
        case topLeft
        case topCenter
        case topRight
        case centerLeft
        case center
        case centerRight
        case bottomLeft
        case bottomCenter
        case bottomRight

        var title: String {
            switch self {
            case .topLeft: "左上"
            case .topCenter: "上中"
            case .topRight: "右上"
            case .centerLeft: "左中"
            case .center: "居中"
            case .centerRight: "右中"
            case .bottomLeft: "左下"
            case .bottomCenter: "下中"
            case .bottomRight: "右下"
            }
        }
    }

    var isEnabled: Bool
    var text: String
    var logoURL: URL?
    var position: Position
    var opacity: CGFloat
    var scale: CGFloat
    var margin: CGFloat
    var textColor: NSColor

    static let `default` = WatermarkConfiguration(
        isEnabled: false,
        text: "",
        logoURL: nil,
        position: .bottomRight,
        opacity: 0.65,
        scale: 1,
        margin: 20,
        textColor: .white
    )

    var hasRenderableContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || logoURL != nil
    }
}

enum WatermarkPreferences {
    private static let enabledKey = "watermark.enabled"
    private static let textKey = "watermark.text"
    private static let logoPathKey = "watermark.logoPath"
    private static let positionKey = "watermark.position"
    private static let opacityKey = "watermark.opacity"
    private static let scaleKey = "watermark.scale"
    private static let marginKey = "watermark.margin"
    private static let colorRedKey = "watermark.textColor.red"
    private static let colorGreenKey = "watermark.textColor.green"
    private static let colorBlueKey = "watermark.textColor.blue"
    private static let colorAlphaKey = "watermark.textColor.alpha"

    static func load(defaults: UserDefaults = .standard) -> WatermarkConfiguration {
        var config = WatermarkConfiguration.default
        if defaults.object(forKey: enabledKey) != nil {
            config.isEnabled = defaults.bool(forKey: enabledKey)
        }
        config.text = defaults.string(forKey: textKey) ?? ""
        if let path = defaults.string(forKey: logoPathKey), !path.isEmpty {
            config.logoURL = URL(fileURLWithPath: path)
        }
        if let value = defaults.string(forKey: positionKey),
           let position = WatermarkConfiguration.Position(rawValue: value) {
            config.position = position
        }
        if defaults.object(forKey: opacityKey) != nil {
            config.opacity = clamp(defaults.double(forKey: opacityKey), min: 0.1, max: 1)
        }
        if defaults.object(forKey: scaleKey) != nil {
            config.scale = clamp(defaults.double(forKey: scaleKey), min: 0.5, max: 2)
        }
        if defaults.object(forKey: marginKey) != nil {
            config.margin = clamp(defaults.double(forKey: marginKey), min: 0, max: 80)
        }
        if defaults.object(forKey: colorRedKey) != nil {
            config.textColor = NSColor(
                calibratedRed: clamp(defaults.double(forKey: colorRedKey), min: 0, max: 1),
                green: clamp(defaults.double(forKey: colorGreenKey), min: 0, max: 1),
                blue: clamp(defaults.double(forKey: colorBlueKey), min: 0, max: 1),
                alpha: clamp(defaults.double(forKey: colorAlphaKey), min: 0, max: 1)
            )
        }
        return config
    }

    static func save(_ config: WatermarkConfiguration, defaults: UserDefaults = .standard) {
        defaults.set(config.isEnabled, forKey: enabledKey)
        defaults.set(config.text, forKey: textKey)
        defaults.set(config.logoURL?.path ?? "", forKey: logoPathKey)
        defaults.set(config.position.rawValue, forKey: positionKey)
        defaults.set(Double(config.opacity), forKey: opacityKey)
        defaults.set(Double(config.scale), forKey: scaleKey)
        defaults.set(Double(config.margin), forKey: marginKey)
        let color = config.textColor.usingColorSpace(.deviceRGB) ?? .white
        defaults.set(Double(color.redComponent), forKey: colorRedKey)
        defaults.set(Double(color.greenComponent), forKey: colorGreenKey)
        defaults.set(Double(color.blueComponent), forKey: colorBlueKey)
        defaults.set(Double(color.alphaComponent), forKey: colorAlphaKey)
    }

    static func setEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        var config = load(defaults: defaults)
        config.isEnabled = enabled
        save(config, defaults: defaults)
    }

    static func importLogo(from sourceURL: URL) throws -> URL {
        guard let image = NSImage(contentsOf: sourceURL),
              let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(
                domain: "SnapInk.Watermark",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "无法读取所选水印图片。"]
            )
        }

        let directory = try supportDirectory()
        let destination = directory.appendingPathComponent("logo.png")
        try data.write(to: destination, options: .atomic)
        return destination
    }

    static func removeLogoFileIfManaged(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().lastPathComponent == "Watermarks" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("SnapInk", isDirectory: true)
            .appendingPathComponent("Watermarks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> CGFloat {
        CGFloat(Swift.min(Swift.max(value, min), max))
    }
}

struct WatermarkContext {
    var capturedAt: Date
}

enum WatermarkRenderer {
    static func render(
        image: CGImage,
        configuration: WatermarkConfiguration,
        context: WatermarkContext = WatermarkContext(capturedAt: Date())
    ) throws -> CGImage {
        guard configuration.isEnabled, configuration.hasRenderableContent else { return image }

        let width = image.width
        let height = image.height
        guard let cgContext = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw makeError(code: 2, message: "无法生成水印图片。")
        }

        cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let logoImage = try loadLogo(from: configuration.logoURL)
        let resolvedText = resolvePlaceholders(in: configuration.text, date: context.capturedAt)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let block = makeBlock(
            text: resolvedText,
            logo: logoImage,
            imageSize: CGSize(width: width, height: height),
            configuration: configuration
        )
        guard block.size.width > 0, block.size.height > 0 else {
            return try requireImage(from: cgContext)
        }

        let origin = blockOrigin(
            blockSize: block.size,
            imageSize: CGSize(width: width, height: height),
            position: configuration.position,
            margin: min(configuration.margin * block.pixelScale, CGFloat(min(width, height)) / 5)
        )

        cgContext.saveGState()
        cgContext.setAlpha(configuration.opacity)
        if let logo = logoImage, !block.logoRect.isEmpty {
            cgContext.draw(logo, in: block.logoRect.offsetBy(dx: origin.x, dy: origin.y))
        }

        if !resolvedText.isEmpty {
            let graphicsContext = NSGraphicsContext(cgContext: cgContext, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphicsContext
            let rect = block.textRect.offsetBy(dx: origin.x, dy: origin.y)
            let shadow = NSShadow()
            shadow.shadowColor = NSColor.black.withAlphaComponent(0.55)
            shadow.shadowBlurRadius = max(2, block.font.pointSize * 0.16)
            shadow.shadowOffset = CGSize(width: 0, height: -1)
            let paragraph = NSMutableParagraphStyle()
            paragraph.alignment = .left
            let attrs: [NSAttributedString.Key: Any] = [
                .font: block.font,
                .foregroundColor: configuration.textColor,
                .shadow: shadow,
                .paragraphStyle: paragraph
            ]
            (resolvedText as NSString).draw(in: rect, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
        cgContext.restoreGState()
        return try requireImage(from: cgContext)
    }

    static func resolvePlaceholders(in text: String, date: Date, locale: Locale = .current) -> String {
        var result = text
        result = result.replacingOccurrences(of: "{datetime}", with: format(date, "yyyy-MM-dd HH:mm:ss", locale: locale))
        result = result.replacingOccurrences(of: "{date}", with: format(date, "yyyy-MM-dd", locale: locale))
        result = result.replacingOccurrences(of: "{time}", with: format(date, "HH:mm:ss", locale: locale))
        return result
    }

    private struct WatermarkBlock {
        var size: CGSize
        var logoRect: CGRect
        var textRect: CGRect
        var font: NSFont
        var pixelScale: CGFloat
    }

    private static func makeBlock(
        text: String,
        logo: CGImage?,
        imageSize: CGSize,
        configuration: WatermarkConfiguration
    ) -> WatermarkBlock {
        let referenceWidth = min(imageSize.width, max(1_440, imageSize.width))
        let pixelScale = max(0.65, min(2.8, referenceWidth / 720))
        var fontSize = 15 * pixelScale * configuration.scale
        fontSize = max(10, min(fontSize, imageSize.width * 0.08))
        let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)
        let gap = text.isEmpty || logo == nil ? 0 : 8 * pixelScale * configuration.scale
        let maxBlockWidth = max(24, imageSize.width - configuration.margin * pixelScale * 2)

        var textSize: CGSize = .zero
        if !text.isEmpty {
            let attrs: [NSAttributedString.Key: Any] = [.font: font]
            textSize = (text as NSString).size(withAttributes: attrs)
            if textSize.width > maxBlockWidth {
                let ratio = maxBlockWidth / textSize.width
                textSize.width *= ratio
                textSize.height *= ratio
            }
        }

        var logoSize: CGSize = .zero
        if let logo {
            let logoHeight = max(textSize.height, 34 * pixelScale * configuration.scale)
            let ratio = CGFloat(logo.width) / CGFloat(max(1, logo.height))
            logoSize = CGSize(width: logoHeight * ratio, height: logoHeight)
            let availableForLogo = maxBlockWidth - textSize.width - gap
            if availableForLogo > 8, logoSize.width > availableForLogo {
                let ratio = availableForLogo / logoSize.width
                logoSize.width *= ratio
                logoSize.height *= ratio
            }
        }

        let blockWidth = logoSize.width + gap + textSize.width
        let blockHeight = max(logoSize.height, textSize.height)
        let logoRect = CGRect(
            x: 0,
            y: (blockHeight - logoSize.height) / 2,
            width: logoSize.width,
            height: logoSize.height
        )
        let textRect = CGRect(
            x: logoSize.width + gap,
            y: (blockHeight - textSize.height) / 2,
            width: textSize.width + 2,
            height: textSize.height + 2
        )
        return WatermarkBlock(
            size: CGSize(width: blockWidth + 2, height: blockHeight + 2),
            logoRect: logoRect,
            textRect: textRect,
            font: font,
            pixelScale: pixelScale
        )
    }

    private static func blockOrigin(
        blockSize: CGSize,
        imageSize: CGSize,
        position: WatermarkConfiguration.Position,
        margin: CGFloat
    ) -> CGPoint {
        let x: CGFloat
        let y: CGFloat
        switch position {
        case .topLeft, .centerLeft, .bottomLeft:
            x = margin
        case .topCenter, .center, .bottomCenter:
            x = (imageSize.width - blockSize.width) / 2
        case .topRight, .centerRight, .bottomRight:
            x = imageSize.width - blockSize.width - margin
        }
        switch position {
        case .topLeft, .topCenter, .topRight:
            y = imageSize.height - blockSize.height - margin
        case .centerLeft, .center, .centerRight:
            y = (imageSize.height - blockSize.height) / 2
        case .bottomLeft, .bottomCenter, .bottomRight:
            y = margin
        }
        return CGPoint(
            x: max(0, min(x, imageSize.width - blockSize.width)),
            y: max(0, min(y, imageSize.height - blockSize.height))
        )
    }

    private static func loadLogo(from url: URL?) throws -> CGImage? {
        guard let url else { return nil }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw makeError(code: 3, message: "无法读取水印图片，请重新选择。")
        }
        return image
    }

    private static func requireImage(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw makeError(code: 4, message: "无法生成水印图片。")
        }
        return image
    }

    private static func format(_ date: Date, _ format: String, locale: Locale) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(domain: "SnapInk.Watermark", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
