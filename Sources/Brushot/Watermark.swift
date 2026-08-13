import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

struct WatermarkConfiguration: Equatable, @unchecked Sendable {
    enum RepeatMode: String, CaseIterable {
        case single
        case diagonalTiled

        var title: String {
            switch self {
            case .single: L.text("单个")
            case .diagonalTiled: L.text("斜向平铺")
            }
        }
    }

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
            case .topLeft: L.text("左上")
            case .topCenter: L.text("上中")
            case .topRight: L.text("右上")
            case .centerLeft: L.text("左中")
            case .center: L.text("居中")
            case .centerRight: L.text("右中")
            case .bottomLeft: L.text("左下")
            case .bottomCenter: L.text("下中")
            case .bottomRight: L.text("右下")
            }
        }
    }

    var isEnabled: Bool
    var text: String
    var logoURL: URL?
    var logoDisplayName: String?
    var repeatMode: RepeatMode
    var position: Position
    var opacity: CGFloat
    var scale: CGFloat
    var margin: CGFloat
    var textColor: NSColor

    static let `default` = WatermarkConfiguration(
        isEnabled: false,
        text: "",
        logoURL: nil,
        logoDisplayName: nil,
        repeatMode: .single,
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
    static let maxLogoFileSize = 3 * 1024 * 1024
    static let maxImportedLogoPixelLength = 1_024
    static let maxSourceLogoPixelLength = 4_096

    private static let enabledKey = "watermark.enabled"
    private static let recordingEnabledKey = "watermark.recordingEnabled"
    private static let textKey = "watermark.text"
    private static let logoPathKey = "watermark.logoPath"
    private static let logoDisplayNameKey = "watermark.logoDisplayName"
    private static let repeatModeKey = "watermark.repeatMode"
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
        if let displayName = defaults.string(forKey: logoDisplayNameKey), !displayName.isEmpty {
            config.logoDisplayName = displayName
        } else {
            config.logoDisplayName = config.logoURL?.lastPathComponent
        }
        if let value = defaults.string(forKey: repeatModeKey),
           let repeatMode = WatermarkConfiguration.RepeatMode(rawValue: value) {
            config.repeatMode = repeatMode
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
        defaults.set(config.logoDisplayName ?? "", forKey: logoDisplayNameKey)
        defaults.set(config.repeatMode.rawValue, forKey: repeatModeKey)
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

    static func recordingEnabled(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: recordingEnabledKey)
    }

    static func setRecordingEnabled(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: recordingEnabledKey)
    }

    static func currentRecordingConfiguration(
        defaults: UserDefaults = .standard
    ) -> WatermarkConfiguration? {
        guard recordingEnabled(defaults: defaults) else { return nil }
        var config = load(defaults: defaults)
        guard config.hasRenderableContent else { return nil }
        config.isEnabled = true
        return config
    }

    static func importLogo(from sourceURL: URL) throws -> URL {
        let fileSize = try logoFileSize(sourceURL)
        guard fileSize <= maxLogoFileSize else {
            throw makeError(
                code: 1,
                message: L.text("Logo 图片不能超过 3MB，请选择更小的 PNG/JPG/HEIC 图片。")
            )
        }

        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            throw makeError(code: 2, message: L.text("无法读取所选水印图片。"))
        }
        try validateLogoType(source)
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0 else {
            throw makeError(code: 3, message: L.text("无法读取所选水印图片尺寸。"))
        }
        guard max(width, height) <= maxSourceLogoPixelLength else {
            throw makeError(
                code: 4,
                message: L.text("Logo 图片最长边不能超过 4096px，请先压缩后再选择。")
            )
        }
        let ratio = CGFloat(max(width, height)) / CGFloat(max(1, min(width, height)))
        let isAcceptableShape = height > width ? ratio <= 2 : ratio <= 6
        guard isAcceptableShape else {
            throw makeError(
                code: 5,
                message: L.text("Logo 图片比例过于细长，请选择独立图标、头像或横向短 Logo。")
            )
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxImportedLogoPixelLength
        ]
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
              let destinationData = NSMutableData() as CFMutableData?,
              let imageDestination = CGImageDestinationCreateWithData(destinationData, UTType.png.identifier as CFString, 1, nil) else {
            throw makeError(code: 6, message: L.text("无法生成水印 Logo 安全副本。"))
        }
        CGImageDestinationAddImage(imageDestination, thumbnail, [
            kCGImageDestinationLossyCompressionQuality: 0.9
        ] as CFDictionary)
        guard CGImageDestinationFinalize(imageDestination) else {
            throw makeError(code: 7, message: L.text("无法保存水印 Logo 安全副本。"))
        }

        let directory = try supportDirectory()
        let destination = directory.appendingPathComponent("logo-\(UUID().uuidString).png")
        try (destinationData as Data).write(to: destination, options: .atomic)
        return destination
    }

    static func removeLogoFileIfManaged(_ url: URL?) {
        guard let url, url.deletingLastPathComponent().lastPathComponent == "Watermarks" else { return }
        try? FileManager.default.removeItem(at: url)
    }

    private static func supportDirectory() throws -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
        let directory = base.appendingPathComponent("Brushot", isDirectory: true)
            .appendingPathComponent("Watermarks", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private static func clamp(_ value: Double, min: Double, max: Double) -> CGFloat {
        CGFloat(Swift.min(Swift.max(value, min), max))
    }

    private static func logoFileSize(_ url: URL) throws -> Int {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return values.fileSize ?? 0
    }

    private static func validateLogoType(_ source: CGImageSource) throws {
        guard let typeIdentifier = CGImageSourceGetType(source) as String?,
              let type = UTType(typeIdentifier),
              type.conforms(to: .png)
                || type.conforms(to: .jpeg)
                || type.conforms(to: .heic) else {
            throw makeError(code: 8, message: L.text("该图片格式不适合作为水印 Logo，请选择 PNG/JPG/HEIC。"))
        }
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(domain: "Brushot.Watermark", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}

struct WatermarkContext {
    var capturedAt: Date
}

enum WatermarkRenderer {
    private final class LogoCacheEntry {
        let image: CGImage

        init(_ image: CGImage) {
            self.image = image
        }
    }

    private final class LogoCache: @unchecked Sendable {
        private let lock = NSLock()
        private let cache = NSCache<NSURL, LogoCacheEntry>()

        func image(for url: URL) -> CGImage? {
            lock.lock()
            defer { lock.unlock() }
            return cache.object(forKey: url as NSURL)?.image
        }

        func set(_ image: CGImage, for url: URL) {
            lock.lock()
            defer { lock.unlock() }
            cache.setObject(LogoCacheEntry(image), forKey: url as NSURL)
        }
    }

    private static let logoCache = LogoCache()

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
            throw makeError(code: 2, message: L.text("无法生成水印图片。"))
        }

        cgContext.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let logoImage = loadLogo(from: configuration.logoURL)
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

        cgContext.saveGState()
        cgContext.setAlpha(configuration.opacity)
        switch configuration.repeatMode {
        case .single:
            let origin = blockOrigin(
                blockSize: block.size,
                imageSize: CGSize(width: width, height: height),
                position: configuration.position,
                margin: min(configuration.margin * block.pixelScale, CGFloat(min(width, height)) / 5)
            )
            drawBlock(
                block,
                at: origin,
                in: cgContext,
                text: resolvedText,
                logo: logoImage,
                configuration: configuration
            )
        case .diagonalTiled:
            drawDiagonalTiles(
                block,
                in: cgContext,
                imageSize: CGSize(width: width, height: height),
                text: resolvedText,
                logo: logoImage,
                configuration: configuration
            )
        }
        cgContext.restoreGState()
        return try requireImage(from: cgContext)
    }

    private static func drawBlock(
        _ block: WatermarkBlock,
        at origin: CGPoint,
        in cgContext: CGContext,
        text: String,
        logo: CGImage?,
        configuration: WatermarkConfiguration
    ) {
        if let logo, !block.logoRect.isEmpty {
            cgContext.draw(logo, in: block.logoRect.offsetBy(dx: origin.x, dy: origin.y))
        }

        if !text.isEmpty {
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
            (text as NSString).draw(in: rect, withAttributes: attrs)
            NSGraphicsContext.restoreGraphicsState()
        }
    }

    private static func drawDiagonalTiles(
        _ block: WatermarkBlock,
        in cgContext: CGContext,
        imageSize: CGSize,
        text: String,
        logo: CGImage?,
        configuration: WatermarkConfiguration
    ) {
        let xStep = max(block.size.width * 2.4, 140 * block.pixelScale)
        let yStep = max(block.size.height * 5, 90 * block.pixelScale)
        let diagonal = hypot(imageSize.width, imageSize.height)
        let originX = -diagonal
        let endX = imageSize.width + diagonal
        let originY = -diagonal
        let endY = imageSize.height + diagonal
        let center = CGPoint(x: imageSize.width / 2, y: imageSize.height / 2)

        var y = originY
        var row = 0
        while y <= endY {
            let rowOffset = row.isMultiple(of: 2) ? 0 : xStep / 2
            var x = originX - rowOffset
            while x <= endX {
                let tileCenter = CGPoint(x: x, y: y)
                cgContext.saveGState()
                cgContext.translateBy(x: center.x, y: center.y)
                cgContext.rotate(by: -.pi / 4)
                cgContext.translateBy(x: -center.x, y: -center.y)
                drawBlock(
                    block,
                    at: CGPoint(
                        x: tileCenter.x - block.size.width / 2,
                        y: tileCenter.y - block.size.height / 2
                    ),
                    in: cgContext,
                    text: text,
                    logo: logo,
                    configuration: configuration
                )
                cgContext.restoreGState()
                x += xStep
            }
            y += yStep
            row += 1
        }
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

    private static func loadLogo(from url: URL?) -> CGImage? {
        guard let url else { return nil }
        if let cached = logoCache.image(for: url) {
            return cached
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        logoCache.set(image, for: url)
        return image
    }

    private static func requireImage(from context: CGContext) throws -> CGImage {
        guard let image = context.makeImage() else {
            throw makeError(code: 4, message: L.text("无法生成水印图片。"))
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
        NSError(domain: "Brushot.Watermark", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
