import AppKit
import CoreGraphics
import Foundation

struct ScreenshotAppearanceConfiguration: Equatable {
    static let shadowSizeRange: ClosedRange<CGFloat> = 0...40
    static let cornerRadiusRange: ClosedRange<CGFloat> = 0...40

    var addsShadow: Bool
    var shadowSize: CGFloat
    var shadowColor: NSColor
    var addsRoundedCorners: Bool
    var cornerRadius: CGFloat

    init(
        addsShadow: Bool,
        shadowSize: CGFloat = 15,
        shadowColor: NSColor = NSColor(calibratedRed: 0.81, green: 0.24, blue: 0.22, alpha: 1),
        addsRoundedCorners: Bool,
        cornerRadius: CGFloat = 18
    ) {
        self.addsShadow = addsShadow
        self.shadowSize = shadowSize
        self.shadowColor = shadowColor
        self.addsRoundedCorners = addsRoundedCorners
        self.cornerRadius = cornerRadius
    }

    static let `default` = ScreenshotAppearanceConfiguration(
        addsShadow: false,
        shadowSize: 15,
        shadowColor: NSColor(calibratedRed: 0.81, green: 0.24, blue: 0.22, alpha: 1),
        addsRoundedCorners: false,
        cornerRadius: 18
    )

    var isDefault: Bool {
        !addsShadow && !addsRoundedCorners
    }
}

enum ScreenshotAppearancePreferences {
    private static let shadowKey = "screenshotAppearance.addsShadow"
    private static let shadowSizeKey = "screenshotAppearance.shadowSize"
    private static let shadowColorRedKey = "screenshotAppearance.shadowColor.red"
    private static let shadowColorGreenKey = "screenshotAppearance.shadowColor.green"
    private static let shadowColorBlueKey = "screenshotAppearance.shadowColor.blue"
    private static let shadowColorAlphaKey = "screenshotAppearance.shadowColor.alpha"
    private static let roundedCornersKey = "screenshotAppearance.addsRoundedCorners"
    private static let cornerRadiusKey = "screenshotAppearance.cornerRadius"

    static func load(defaults: UserDefaults = .standard) -> ScreenshotAppearanceConfiguration {
        var configuration = ScreenshotAppearanceConfiguration.default
        configuration.addsShadow = defaults.bool(forKey: shadowKey)
        configuration.addsRoundedCorners = defaults.bool(forKey: roundedCornersKey)
        if defaults.object(forKey: shadowSizeKey) != nil {
            configuration.shadowSize = clamp(
                defaults.double(forKey: shadowSizeKey),
                range: ScreenshotAppearanceConfiguration.shadowSizeRange
            )
        }
        if defaults.object(forKey: cornerRadiusKey) != nil {
            configuration.cornerRadius = clamp(
                defaults.double(forKey: cornerRadiusKey),
                range: ScreenshotAppearanceConfiguration.cornerRadiusRange
            )
        }
        if defaults.object(forKey: shadowColorRedKey) != nil {
            configuration.shadowColor = NSColor(
                calibratedRed: clamp(defaults.double(forKey: shadowColorRedKey), range: 0...1),
                green: clamp(defaults.double(forKey: shadowColorGreenKey), range: 0...1),
                blue: clamp(defaults.double(forKey: shadowColorBlueKey), range: 0...1),
                alpha: clamp(defaults.double(forKey: shadowColorAlphaKey), range: 0...1)
            )
        }
        return configuration
    }

    static func save(_ configuration: ScreenshotAppearanceConfiguration, defaults: UserDefaults = .standard) {
        defaults.set(configuration.addsShadow, forKey: shadowKey)
        defaults.set(Double(clamp(configuration.shadowSize, range: ScreenshotAppearanceConfiguration.shadowSizeRange)), forKey: shadowSizeKey)
        let shadowColor = configuration.shadowColor.usingColorSpace(.deviceRGB)
            ?? ScreenshotAppearanceConfiguration.default.shadowColor
        defaults.set(Double(shadowColor.redComponent), forKey: shadowColorRedKey)
        defaults.set(Double(shadowColor.greenComponent), forKey: shadowColorGreenKey)
        defaults.set(Double(shadowColor.blueComponent), forKey: shadowColorBlueKey)
        defaults.set(Double(shadowColor.alphaComponent), forKey: shadowColorAlphaKey)
        defaults.set(configuration.addsRoundedCorners, forKey: roundedCornersKey)
        defaults.set(Double(clamp(configuration.cornerRadius, range: ScreenshotAppearanceConfiguration.cornerRadiusRange)), forKey: cornerRadiusKey)
    }

    static func setAddsShadow(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: shadowKey)
    }

    static func setAddsRoundedCorners(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: roundedCornersKey)
    }

    static func setShadowSize(_ size: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(size, range: ScreenshotAppearanceConfiguration.shadowSizeRange)), forKey: shadowSizeKey)
    }

    static func setShadowColor(_ color: NSColor, defaults: UserDefaults = .standard) {
        var configuration = load(defaults: defaults)
        configuration.shadowColor = color
        save(configuration, defaults: defaults)
    }

    static func setCornerRadius(_ radius: CGFloat, defaults: UserDefaults = .standard) {
        defaults.set(Double(clamp(radius, range: ScreenshotAppearanceConfiguration.cornerRadiusRange)), forKey: cornerRadiusKey)
    }

    private static func clamp(_ value: Double, range: ClosedRange<CGFloat>) -> CGFloat {
        clamp(CGFloat(value), range: range)
    }

    private static func clamp(_ value: CGFloat, range: ClosedRange<CGFloat>) -> CGFloat {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum ScreenshotAppearanceRenderer {
    static func render(
        image: CGImage,
        configuration: ScreenshotAppearanceConfiguration = ScreenshotAppearancePreferences.load()
    ) throws -> CGImage {
        guard !configuration.isDefault else { return image }

        let imageSize = CGSize(width: image.width, height: image.height)
        let cornerRadius = configuration.addsRoundedCorners ? configuration.cornerRadius : 0
        let shadowBlur = configuration.addsShadow ? configuration.shadowSize : 0
        let shadowOffset = CGSize(width: 0, height: -max(2, shadowBlur * 0.35))
        let padding = configuration.addsShadow ? ceil(shadowBlur + abs(shadowOffset.height) + 6) : 0
        let outputWidth = image.width + Int(padding * 2)
        let outputHeight = image.height + Int(padding * 2)

        guard let context = CGContext(
            data: nil,
            width: outputWidth,
            height: outputHeight,
            bitsPerComponent: 8,
            bytesPerRow: outputWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw makeError(code: 1, message: L.text("无法生成截图外观。"))
        }

        let imageRect = CGRect(
            x: padding,
            y: padding,
            width: imageSize.width,
            height: imageSize.height
        )
        let shapePath = roundedPath(in: imageRect, radius: cornerRadius)

        context.clear(CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight))
        if configuration.addsShadow {
            context.saveGState()
            context.setShadow(
                offset: shadowOffset,
                blur: shadowBlur,
                color: shadowCGColor(configuration.shadowColor, alphaMultiplier: 0.65)
            )
            context.addPath(shapePath)
            context.setFillColor(NSColor.black.cgColor)
            context.fillPath()
            context.restoreGState()
        }

        context.saveGState()
        context.addPath(shapePath)
        context.clip()
        context.draw(image, in: imageRect)
        context.restoreGState()

        guard let output = context.makeImage() else {
            throw makeError(code: 2, message: L.text("无法生成截图外观。"))
        }
        return output
    }

    private static func roundedPath(in rect: CGRect, radius: CGFloat) -> CGPath {
        guard radius > 0 else { return CGPath(rect: rect, transform: nil) }
        return CGPath(
            roundedRect: rect,
            cornerWidth: min(radius, rect.width / 2),
            cornerHeight: min(radius, rect.height / 2),
            transform: nil
        )
    }

    private static func shadowCGColor(_ color: NSColor, alphaMultiplier: CGFloat) -> CGColor {
        let rgb = color.usingColorSpace(.deviceRGB)
            ?? ScreenshotAppearanceConfiguration.default.shadowColor
        return rgb.withAlphaComponent(min(max(rgb.alphaComponent * alphaMultiplier, 0), 1)).cgColor
    }

    private static func makeError(code: Int, message: String) -> NSError {
        NSError(domain: "Brushot.ScreenshotAppearance", code: code, userInfo: [NSLocalizedDescriptionKey: message])
    }
}
