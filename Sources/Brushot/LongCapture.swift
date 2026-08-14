import AppKit
import Foundation
import Vision

enum LongCaptureAppendResult: Equatable {
    case appended(newPixelRows: Int, totalPixelHeight: Int)
    case duplicate
}

enum LongCaptureStitchError: LocalizedError, Equatable {
    case invalidFrame
    case inconsistentFrameSize
    case noReliableOverlap
    case reverseScrollDetected
    case imageTooLarge
    case renderingFailed

    var errorDescription: String? {
        switch self {
        case .invalidFrame:
            L.text("无法读取长截图画面。")
        case .inconsistentFrameSize:
            L.text("截图区域尺寸发生变化，请重新开始长截图。")
        case .noReliableOverlap:
            L.text("没有识别到连续内容，请减小滚动距离，并确保框选区域内没有固定栏或动画。")
        case .reverseScrollDetected:
            L.text("检测到向上回滚，已自动完成长截图。")
        case .imageTooLarge:
            L.text("长截图已达到尺寸上限，请先完成并保存当前内容。")
        case .renderingFailed:
            L.text("无法生成拼接后的长截图。")
        }
    }
}

struct LongCaptureMatch: Equatable {
    let displacement: Int
    let score: Double
    let confidence: Double
}

/// Incrementally joins equal-sized screenshots captured while their source
/// content scrolls vertically. Frames remain lossless RGBA so the final PNG is
/// not repeatedly encoded while capture is in progress.
final class LongCaptureStitcher {
    static let maximumPixelHeight = 60_000
    static let maximumDecodedBytes = 256 * 1_024 * 1_024

    private struct RasterFrame {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let data: Data

        init(image: CGImage) throws {
            guard image.width > 1, image.height > 1 else {
                throw LongCaptureStitchError.invalidFrame
            }
            let rasterWidth = image.width
            let rasterHeight = image.height
            let rasterBytesPerRow = rasterWidth * 4
            var storage = Data(count: rasterBytesPerRow * rasterHeight)
            let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            let rendered = storage.withUnsafeMutableBytes { bytes -> Bool in
                guard let baseAddress = bytes.baseAddress,
                      let context = CGContext(
                        data: baseAddress,
                        width: rasterWidth,
                        height: rasterHeight,
                        bitsPerComponent: 8,
                        bytesPerRow: rasterBytesPerRow,
                        space: colorSpace,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                            | CGBitmapInfo.byteOrder32Big.rawValue
                      ) else { return false }
                context.interpolationQuality = .none
                context.draw(image, in: CGRect(x: 0, y: 0, width: rasterWidth, height: rasterHeight))
                return true
            }
            guard rendered else {
                throw LongCaptureStitchError.invalidFrame
            }
            width = rasterWidth
            height = rasterHeight
            bytesPerRow = rasterBytesPerRow
            data = storage
        }

    }

    private struct Segment {
        let rgbaData: Data
        let newPixelRows: Int
        let previewImage: CGImage
    }

    private let firstFrame: RasterFrame
    private var firstPreviewImage: CGImage
    private var latestFrame: RasterFrame
    private var latestImage: CGImage
    private var segments: [Segment] = []
    private var stableBottomInset = 0
    private var stableBottomPreviewImage: CGImage?
    private(set) var pixelHeight: Int

    var frameCount: Int { segments.count + 1 }
    var pixelWidth: Int { firstFrame.width }
    var previewSegmentImages: [CGImage] {
        [firstPreviewImage]
            + segments.map(\.previewImage)
            + (stableBottomPreviewImage.map { [$0] } ?? [])
    }

    init(firstFrame: CGImage) throws {
        let raster = try RasterFrame(image: firstFrame)
        self.firstFrame = raster
        firstPreviewImage = firstFrame
        latestFrame = raster
        latestImage = firstFrame
        pixelHeight = raster.height
        try validateSize(width: raster.width, height: raster.height)
    }

    func append(_ image: CGImage) throws -> LongCaptureAppendResult {
        let next = try RasterFrame(image: image)
        guard next.width == latestFrame.width, next.height == latestFrame.height else {
            throw LongCaptureStitchError.inconsistentFrameSize
        }

        if Self.averageDifference(latestFrame, next, displacement: 0) < 1.25 {
            return .duplicate
        }

        // Reverse scroll (the user scrolled back up, or the content reached
        // its bottom and elastically rebounded): the current frame shifted
        // DOWN relative to the previous one. Following iShot's behavior, stop
        // capture immediately rather than risk overlapping/stacking content.
        //
        // Vision's full-frame registration gives a candidate displacement for
        // how `current` aligns to `previous`; for a reverse scroll that is a
        // (possibly periodic-aliased) shift D whose magnitude, applied to
        // `current`, realigns it almost perfectly with `previous` — i.e.
        // averageDifference(current, previous, |D|) is near zero. A genuine
        // forward scroll is misaligned by ~2|D|, so the check never fires on
        // real down-scrolls (including fast scrolls where Vision may report a
        // negative periodic alias that does NOT realign). This runs before
        // bestVerticalMatch so the periodic-alias-prone scan fallback cannot
        // match such a frame.
        let full = Self.findTranslation(from: image, to: latestImage)
        if let full = full {
            let absDy = abs(Int(full.y.rounded()))
            if absDy > 0,
               Self.averageDifference(next, latestFrame, displacement: absDy) < 4 {
                throw LongCaptureStitchError.reverseScrollDetected
            }
        }

        guard let match = Self.bestVerticalMatch(
            previousImage: latestImage,
            currentImage: image,
            previous: latestFrame,
            current: next,
            frameHeight: next.height,
            full: full
        ) else {
            throw LongCaptureStitchError.noReliableOverlap
        }
        if stableBottomInset == 0, segments.count <= 4 {
            let detectedInset = Self.detectStableBottomInset(previous: latestFrame, current: next)
            if detectedInset > 0, detectedInset < firstFrame.height {
                stableBottomInset = detectedInset
                let firstBodyEnd = (firstFrame.height - detectedInset) * firstFrame.bytesPerRow
                firstPreviewImage = try Self.makeRGBAImage(
                    width: firstFrame.width,
                    height: firstFrame.height - detectedInset,
                    data: Data(firstFrame.data[..<firstBodyEnd])
                )
            }
        }
        let newHeight = pixelHeight + match.displacement
        try validateSize(width: next.width, height: newHeight)
        let scrollingBottom = next.height - stableBottomInset
        let sourceStart = (scrollingBottom - match.displacement) * next.bytesPerRow
        let sourceEnd = sourceStart + match.displacement * next.bytesPerRow
        guard sourceStart >= 0, sourceEnd <= next.data.count else {
            throw LongCaptureStitchError.noReliableOverlap
        }
        let newRows = Data(next.data[sourceStart..<sourceEnd])
        let previewImage = try Self.makeRGBAImage(
            width: next.width,
            height: match.displacement,
            data: newRows
        )
        segments.append(Segment(
            rgbaData: newRows,
            newPixelRows: match.displacement,
            previewImage: previewImage
        ))
        latestFrame = next
        latestImage = image
        if stableBottomInset > 0 {
            let footerStart = (next.height - stableBottomInset) * next.bytesPerRow
            stableBottomPreviewImage = try Self.makeRGBAImage(
                width: next.width,
                height: stableBottomInset,
                data: Data(next.data[footerStart..<next.data.count])
            )
        }
        pixelHeight = newHeight
        return .appended(newPixelRows: match.displacement, totalPixelHeight: newHeight)
    }

    func renderedImage() throws -> CGImage {
        try validateSize(width: pixelWidth, height: pixelHeight)
        let bytesPerRow = pixelWidth * 4
        var output = Data(count: bytesPerRow * pixelHeight)
        output.withUnsafeMutableBytes { destinationBytes in
            guard let destination = destinationBytes.baseAddress else { return }
            let firstBodyHeight = firstFrame.height - stableBottomInset
            firstFrame.data.withUnsafeBytes { sourceBytes in
                guard let source = sourceBytes.baseAddress else { return }
                memcpy(destination, source, firstFrame.bytesPerRow * firstBodyHeight)
            }

            var destinationRow = firstBodyHeight
            for segment in segments {
                segment.rgbaData.withUnsafeBytes { sourceBytes in
                    guard let source = sourceBytes.baseAddress else { return }
                    memcpy(
                        destination.advanced(by: destinationRow * bytesPerRow),
                        source,
                        segment.newPixelRows * bytesPerRow
                    )
                }
                destinationRow += segment.newPixelRows
            }
            if stableBottomInset > 0 {
                latestFrame.data.withUnsafeBytes { sourceBytes in
                    guard let source = sourceBytes.baseAddress else { return }
                    memcpy(
                        destination.advanced(by: destinationRow * bytesPerRow),
                        source.advanced(by: (latestFrame.height - stableBottomInset) * bytesPerRow),
                        stableBottomInset * bytesPerRow
                    )
                }
            }
        }

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        let result: CGImage? = output.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress,
                  let context = CGContext(
                    data: baseAddress,
                    width: pixelWidth,
                    height: pixelHeight,
                    bitsPerComponent: 8,
                    bytesPerRow: bytesPerRow,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                  ) else { return nil }
            return context.makeImage()
        }
        guard let result else { throw LongCaptureStitchError.renderingFailed }
        return result
    }

    private func validateSize(width: Int, height: Int) throws {
        let (pixelCount, pixelOverflow) = width.multipliedReportingOverflow(by: height)
        let (byteCount, byteOverflow) = pixelCount.multipliedReportingOverflow(by: 4)
        guard !pixelOverflow,
              !byteOverflow,
              height <= Self.maximumPixelHeight,
              byteCount <= Self.maximumDecodedBytes else {
            throw LongCaptureStitchError.imageTooLarge
        }
    }

    private static func makeRGBAImage(width: Int, height: Int, data: Data) throws -> CGImage {
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGBitmapInfo(
                    rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                        | CGBitmapInfo.byteOrder32Big.rawValue
                ),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw LongCaptureStitchError.renderingFailed
        }
        return image
    }

    private static func detectStableBottomInset(
        previous: RasterFrame,
        current: RasterFrame
    ) -> Int {
        let maximumInset = min(previous.height / 4, 240)
        let minimumInset = max(8, previous.height / 100)
        let horizontalInset = min(20, max(2, previous.width / 20))
        guard maximumInset >= minimumInset,
              previous.width > horizontalInset * 2 else { return 0 }

        var stableRows = 0
        previous.data.withUnsafeBytes { previousRaw in
            current.data.withUnsafeBytes { currentRaw in
                let previousBytes = previousRaw.bindMemory(to: UInt8.self)
                let currentBytes = currentRaw.bindMemory(to: UInt8.self)
                for rowOffset in 1...maximumInset {
                    let y = previous.height - rowOffset
                    var changedPixels = 0
                    for x in horizontalInset..<(previous.width - horizontalInset) {
                        let offset = y * previous.bytesPerRow + x * 4
                        let channelDifference =
                            abs(Int(previousBytes[offset]) - Int(currentBytes[offset]))
                            + abs(Int(previousBytes[offset + 1]) - Int(currentBytes[offset + 1]))
                            + abs(Int(previousBytes[offset + 2]) - Int(currentBytes[offset + 2]))
                        if channelDifference > 12 {
                            changedPixels += 1
                            if changedPixels > 2 { break }
                        }
                    }
                    guard changedPixels <= 2 else { break }
                    stableRows += 1
                }
            }
        }
        return stableRows >= minimumInset ? stableRows : 0
    }

    private static func bestVerticalMatch(
        previousImage: CGImage,
        currentImage: CGImage,
        previous: RasterFrame,
        current: RasterFrame,
        frameHeight: Int,
        full: (x: CGFloat, y: CGFloat, confidence: Float)?
    ) -> LongCaptureMatch? {
        if let visionMatch = visionMatch(
            previousImage: previousImage,
            currentImage: currentImage,
            previous: previous,
            current: current,
            frameHeight: frameHeight,
            full: full
        ) {
            return visionMatch
        }
        // Fallback for low-overlap frames where Vision's single global guess
        // is unreliable (for example only ~10% overlap during fast scrolling):
        // a brute-force pixel scan that finds the best-scoring displacement
        // across the whole overlap range with a confidence gate.
        return scanBestDisplacement(previous: previous, current: current)
    }

    private static func visionMatch(
        previousImage: CGImage,
        currentImage: CGImage,
        previous: RasterFrame,
        current: RasterFrame,
        frameHeight: Int,
        full: (x: CGFloat, y: CGFloat, confidence: Float)?
    ) -> LongCaptureMatch? {
        // Primary: Apple Vision's translational image registration (FFT-based,
        // fast, global) on the full frame. No scroll-delta prediction and no
        // bounded search window are needed: it finds the offset across the
        // whole frame in one shot, so it tolerates the large per-frame
        // displacements of fast scrolling without dropping frames. Horizontal
        // movement is ignored because long capture only stitches vertical
        // scroll, and horizontally periodic content makes Vision lock onto a
        // horizontal alias anyway.
        let maximumVerticalMovement = CGFloat(frameHeight) * 0.94
        guard let full = full else {
            return nil
        }
        let fullDy = Int(full.y.rounded())
        guard full.confidence >= 0.3,
              abs(CGFloat(fullDy)) <= maximumVerticalMovement,
              fullDy > 0 else {
            return nil
        }
        var resolved = fullDy

        // For small/medium scrolls the comparison bands still overlap the true
        // displacement, so they can validate the full-frame result. Periodic
        // content can make a full-frame match lock onto an alias (true + a
        // multiple of the repeat period); bands with distinctive content then
        // disagree, so prefer the band consensus when it differs. Large scrolls
        // move past a single band's height, so the bands cannot overlap and we
        // keep the full-frame match.
        let bandHeight = CGFloat(min(frameHeight, max(80, frameHeight / 3)))
        if CGFloat(fullDy) < bandHeight {
            let bands = comparisonBands(
                imageWidth: previousImage.width,
                imageHeight: previousImage.height,
                bandCount: 5,
                minimumBandHeight: 80
            )
            var bandTranslations: [(y: Int, confidence: Float)] = []
            for band in bands {
                guard let currentBand = currentImage.cropping(to: band),
                      let previousBand = previousImage.cropping(to: band),
                      let translation = findTranslation(from: currentBand, to: previousBand)
                else { continue }
                let bandDy = Int(translation.y.rounded())
                guard translation.confidence >= 0.5,
                      abs(CGFloat(bandDy)) <= maximumVerticalMovement,
                      bandDy > 0 else { continue }
                bandTranslations.append((bandDy, translation.confidence))
            }
            if let consensus = bestGroup(in: bandTranslations, tolerance: 3, minimumCount: 4) {
                let averaged = average(consensus)
                if abs(averaged.y - fullDy) > 3 {
                    resolved = averaged.y
                }
            }
        }

        // Verify the proposed displacement produces a genuine pixel overlap.
        // This separates a real scroll from an unrelated frame or a large-D
        // alias that slipped past the bands: true overlaps match almost
        // perfectly, while unrelated or misaligned frames do not.
        guard averageDifference(previous, current, displacement: resolved) <= 18 else {
            return nil
        }
        return LongCaptureMatch(
            displacement: resolved,
            score: Double(full.confidence),
            confidence: Double(full.confidence)
        )
    }

    private static func scanBestDisplacement(
        previous: RasterFrame,
        current: RasterFrame
    ) -> LongCaptureMatch? {
        // Coarse-to-fine pixel scan across the full overlap range. Used only
        // when the Vision registration is unreliable (low-overlap fast scroll),
        // so the periodic-alias risk that motivated the Vision path does not
        // apply here. The confidence gate requires the best displacement to be
        // clearly better than any alternative so unrelated frames are rejected.
        let absoluteMinimum = max(2, previous.height / 200)
        let absoluteMaximum = max(
            absoluteMinimum,
            min(previous.height - 28, Int(Double(previous.height) * 0.94))
        )
        guard absoluteMaximum >= absoluteMinimum else { return nil }

        var bestDisplacement = absoluteMinimum
        var bestScore = averageDifference(previous, current, displacement: absoluteMinimum)
        var secondScore = 255.0
        let coarseStep = max(1, (absoluteMaximum - absoluteMinimum) / 96)
        var displacement = absoluteMinimum + coarseStep
        while displacement <= absoluteMaximum {
            let score = averageDifference(previous, current, displacement: displacement)
            if score < bestScore {
                secondScore = bestScore
                bestScore = score
                bestDisplacement = displacement
            } else if score < secondScore, abs(displacement - bestDisplacement) >= 4 {
                secondScore = score
            }
            displacement += coarseStep
        }
        let lower = max(absoluteMinimum, bestDisplacement - 3)
        let upper = min(absoluteMaximum, bestDisplacement + 3)
        for refined in lower...upper {
            let score = averageDifference(previous, current, displacement: refined)
            if score < bestScore {
                secondScore = bestScore
                bestScore = score
                bestDisplacement = refined
            } else if score < secondScore, abs(refined - bestDisplacement) >= 4 {
                secondScore = score
            }
        }
        let confidence = secondScore - bestScore
        guard bestScore <= 18, confidence >= 0.35 else { return nil }
        return LongCaptureMatch(
            displacement: bestDisplacement,
            score: bestScore,
            confidence: confidence
        )
    }

    private static func comparisonBands(
        imageWidth: Int,
        imageHeight: Int,
        bandCount: Int,
        minimumBandHeight: Int
    ) -> [CGRect] {
        guard imageWidth > 0, imageHeight > 0 else { return [] }
        let bandHeight = min(imageHeight, max(minimumBandHeight, imageHeight / 3))
        let maxOriginY = max(0, imageHeight - bandHeight)
        if maxOriginY == 0 {
            return [CGRect(x: 0, y: 0, width: imageWidth, height: bandHeight)]
        }
        let origins = Set((0..<bandCount).map { index in
            Int((CGFloat(maxOriginY) * CGFloat(index) / CGFloat(max(1, bandCount - 1))).rounded())
        })
        return origins.sorted().map {
            CGRect(x: 0, y: $0, width: imageWidth, height: bandHeight)
        }
    }

    private static func findTranslation(
        from source: CGImage,
        to target: CGImage
    ) -> (x: CGFloat, y: CGFloat, confidence: Float)? {
        let request = VNTranslationalImageRegistrationRequest(targetedCGImage: target)
        let handler = VNImageRequestHandler(cgImage: source, options: [:])
        do {
            try handler.perform([request])
        } catch {
            return nil
        }
        guard let observation = request.results?.first
            as? VNImageTranslationAlignmentObservation else { return nil }
        return (
            observation.alignmentTransform.tx,
            observation.alignmentTransform.ty,
            observation.confidence
        )
    }

    private static func bestGroup(
        in translations: [(y: Int, confidence: Float)],
        tolerance: Int,
        minimumCount: Int
    ) -> [(y: Int, confidence: Float)]? {
        var best: [(y: Int, confidence: Float)] = []
        for translation in translations {
            let group = translations.filter { abs($0.y - translation.y) <= tolerance }
            if group.count > best.count { best = group }
        }
        return best.count >= minimumCount ? best : nil
    }

    private static func average(
        _ translations: [(y: Int, confidence: Float)]
    ) -> (y: Int, confidence: Float) {
        let count = translations.count
        let sumY = translations.reduce(0) { $0 + $1.y }
        let sumConfidence = translations.reduce(Float(0)) { $0 + $1.confidence }
        return (
            Int((CGFloat(sumY) / CGFloat(count)).rounded()),
            sumConfidence / Float(count)
        )
    }

    private static func averageDifference(
        _ previous: RasterFrame,
        _ current: RasterFrame,
        displacement: Int
    ) -> Double {
        difference(
            previous,
            current,
            displacement: displacement,
            horizontalSamples: 32,
            verticalSamples: 72
        )
    }

    private static func difference(
        _ previous: RasterFrame,
        _ current: RasterFrame,
        displacement: Int,
        horizontalSamples: Int,
        verticalSamples: Int
    ) -> Double {
        let overlap = previous.height - displacement
        guard overlap > 8 else { return 255 }
        let horizontalInset = max(2, previous.width / 12)
        let availableWidth = max(1, previous.width - horizontalInset * 2)
        let xStep = max(1, availableWidth / horizontalSamples)
        let verticalInset = min(4, overlap / 8)
        let availableHeight = max(1, overlap - verticalInset * 2)
        let yStep = max(1, availableHeight / verticalSamples)

        var accumulatedDifference = 0
        var sampleCount = 0
        previous.data.withUnsafeBytes { previousRaw in
            current.data.withUnsafeBytes { currentRaw in
                let previousBytes = previousRaw.bindMemory(to: UInt8.self)
                let currentBytes = currentRaw.bindMemory(to: UInt8.self)
                var y = verticalInset
                while y < overlap - verticalInset {
                    var x = horizontalInset
                    while x < previous.width - horizontalInset {
                        let previousOffset = (y + displacement) * previous.bytesPerRow + x * 4
                        let currentOffset = y * current.bytesPerRow + x * 4
                        accumulatedDifference += (
                            abs(Int(previousBytes[previousOffset]) - Int(currentBytes[currentOffset]))
                                + abs(Int(previousBytes[previousOffset + 1]) - Int(currentBytes[currentOffset + 1]))
                                + abs(Int(previousBytes[previousOffset + 2]) - Int(currentBytes[currentOffset + 2]))
                        ) / 3
                        sampleCount += 1
                        x += xStep
                    }
                    y += yStep
                }
            }
        }
        guard sampleCount > 0 else { return 255 }
        return Double(accumulatedDifference) / Double(sampleCount)
    }
}

@MainActor
final class LongCaptureStartBar: NSVisualEffectView {
    var onStart: (() -> Void)?
    var onCancel: (() -> Void)?

    init(frame frameRect: NSRect, hint: String = L.text("框内内容需全部能够上下滚动"), startTitle: String = L.text("开始长截图")) {
        super.init(frame: frameRect)
        material = .hudWindow
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        let hintLabel = NSTextField(labelWithString: hint)
        hintLabel.font = .systemFont(ofSize: 12)
        hintLabel.textColor = .secondaryLabelColor
        let cancel = NSButton(title: L.text("取消"), target: self, action: #selector(cancelAction))
        let start = NSButton(title: startTitle, target: self, action: #selector(startAction))
        start.keyEquivalent = "\r"
        start.bezelStyle = .rounded
        start.contentTintColor = .controlAccentColor
        let stack = NSStackView(views: [hintLabel, cancel, start])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    @objc private func startAction() { onStart?() }
    @objc private func cancelAction() { onCancel?() }
}

private final class LongCaptureBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlAccentColor.setStroke()
        // The window extends three points beyond the selected capture area.
        // Keeping the stroke one point outside that area prevents the visual
        // guide from ever becoming part of the stitched pixels.
        let border = NSBezierPath(rect: bounds.insetBy(dx: 1, dy: 1))
        border.lineWidth = 2
        border.stroke()
    }
}

private final class LongCaptureLivePreviewView: NSView {
    private var images: [CGImage] = []
    private var sourcePixelWidth = 1

    override var isFlipped: Bool { true }

    func update(images: [CGImage], sourcePixelWidth: Int, displayWidth: CGFloat) {
        self.images = images
        self.sourcePixelWidth = max(1, sourcePixelWidth)
        let scale = max(1, displayWidth) / CGFloat(self.sourcePixelWidth)
        let displayHeight = images.reduce(CGFloat.zero) {
            $0 + CGFloat($1.height) * scale
        }
        setFrameSize(CGSize(width: max(1, displayWidth), height: max(1, ceil(displayHeight))))
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        guard !images.isEmpty else { return }
        NSGraphicsContext.current?.imageInterpolation = .medium
        let scale = bounds.width / CGFloat(sourcePixelWidth)
        var y: CGFloat = 0
        for image in images {
            let height = CGFloat(image.height) * scale
            let destination = CGRect(x: 0, y: y, width: bounds.width, height: height)
            if destination.intersects(dirtyRect) {
                NSImage(cgImage: image, size: destination.size).draw(
                    in: destination,
                    from: .zero,
                    operation: .copy,
                    fraction: 1,
                    respectFlipped: true,
                    hints: [.interpolation: NSImageInterpolation.medium]
                )
            }
            y += height
        }
    }
}

private final class LongCaptureOverlayPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the live scrolling phase after the capture rectangle has been chosen.
/// The border ignores input so wheel events continue to reach the underlying
/// browser or document, while a small independent panel provides Finish and
/// Cancel actions.
@MainActor
final class LongCaptureSessionController: NSObject {
    typealias CaptureFrame = @MainActor () async throws -> CGImage

    private let selectionRect: CGRect
    private let captureFrame: CaptureFrame
    private let onFinish: (CGImage, CGFloat) -> Void
    private let onCancel: () -> Void
    private let onError: (Error) -> Void
    private let stitcher: LongCaptureStitcher
    private let pixelScale: CGFloat
    private let borderWindow: NSWindow
    private let controlWindow: LongCaptureOverlayPanel
    private let previewWindow: NSPanel
    private let statusLabel = NSTextField(labelWithString: "")
    private let previewStatusLabel = NSTextField(labelWithString: "")
    private let previewScrollView = NSScrollView()
    private let livePreviewView = LongCaptureLivePreviewView()
    private let finishButton = NSButton(title: L.text("完成"), target: nil, action: nil)
    private let cancelButton = NSButton(title: L.text("取消"), target: nil, action: nil)
    private var globalScrollMonitor: Any?
    private var captureTimer: Timer?
    private var isCapturing = false
    private var pendingCapture = false
    private var finishWhenIdle = false
    private var isFinished = false
    private var lastCaptureStartedAt = Date.distantPast
    private var lastScrollEventAt = Date.distantPast

    nonisolated static let minimumCaptureInterval: TimeInterval = 0.04
    nonisolated static let scrollActivityTail: TimeInterval = 0.20
    nonisolated static let borderExpansion: CGFloat = 3

    nonisolated static func borderFrame(for selectionRect: CGRect) -> CGRect {
        selectionRect.insetBy(dx: -borderExpansion, dy: -borderExpansion)
    }

    var visibleOverlayWindowCount: Int {
        [borderWindow, controlWindow, previewWindow].filter(\.isVisible).count
    }

    var livePreviewHeightText: String { previewStatusLabel.stringValue }
    var livePreviewSegmentCount: Int { stitcher.previewSegmentImages.count }
    var livePreviewWindowFrame: CGRect { previewWindow.frame }
    var instructionText: String { statusLabel.stringValue }

    static var instruction: String { L.text("向下滚动采集；向上滚动立即完成，或点“完成”") }

    /// The instruction rendered with the "向上滚动立即完成" segment emphasized
    /// (semibold + accent color) so the auto-finish-on-reverse behavior is
    /// noticeable at a glance while the rest stays in the subdued base style.
    static var instructionAttributed: NSAttributedString {
        let text = instruction
        let result = NSMutableAttributedString(string: text)
        let baseRange = NSRange(location: 0, length: text.utf16.count)
        result.addAttributes([
            .font: NSFont.systemFont(ofSize: 13, weight: .medium),
            .foregroundColor: NSColor.secondaryLabelColor
        ], range: baseRange)
        let highlight = L.text("向上滚动立即完成")
        if let range = text.range(of: highlight) {
            result.addAttributes([
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
                .foregroundColor: NSColor.controlAccentColor
            ], range: NSRange(range, in: text))
        }
        return result
    }

    init(
        selectionRect: CGRect,
        firstFrame: CGImage,
        captureFrame: @escaping CaptureFrame,
        onFinish: @escaping (CGImage, CGFloat) -> Void,
        onCancel: @escaping () -> Void,
        onError: @escaping (Error) -> Void
    ) throws {
        self.selectionRect = selectionRect
        self.captureFrame = captureFrame
        self.onFinish = onFinish
        self.onCancel = onCancel
        self.onError = onError
        stitcher = try LongCaptureStitcher(firstFrame: firstFrame)
        pixelScale = CGFloat(firstFrame.width) / max(1, selectionRect.width)

        let borderFrame = Self.borderFrame(for: selectionRect)
        let border = LongCaptureBorderView(frame: CGRect(origin: .zero, size: borderFrame.size))
        borderWindow = NSWindow(
            contentRect: borderFrame,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        borderWindow.contentView = border
        borderWindow.backgroundColor = .clear
        borderWindow.isOpaque = false
        borderWindow.hasShadow = false
        borderWindow.ignoresMouseEvents = true
        borderWindow.level = .screenSaver
        borderWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        borderWindow.isReleasedWhenClosed = false

        controlWindow = LongCaptureOverlayPanel(
            contentRect: CGRect(x: 0, y: 0, width: 370, height: 58),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        previewWindow = NSPanel(
            contentRect: CGRect(x: 0, y: 0, width: 220, height: 420),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configureControlPanel()
        configurePreviewPanel()
    }

    func start() {
        guard !isFinished else { return }
        positionControlPanel()
        positionPreviewPanel()
        borderWindow.orderFrontRegardless()
        controlWindow.orderFrontRegardless()
        previewWindow.orderFrontRegardless()
        updateInstruction()
        updateLivePreview()
        globalScrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            Task { @MainActor in
                self?.receivedScroll(event)
            }
        }
    }

    private func configureControlPanel() {
        controlWindow.isOpaque = false
        controlWindow.backgroundColor = .clear
        controlWindow.hasShadow = true
        controlWindow.hidesOnDeactivate = false
        controlWindow.isReleasedWhenClosed = false
        controlWindow.level = .screenSaver
        controlWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: controlWindow.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        controlWindow.contentView = background

        statusLabel.font = .systemFont(ofSize: 13, weight: .medium)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        finishButton.target = self
        finishButton.action = #selector(finishAction)
        finishButton.keyEquivalent = "\r"
        cancelButton.target = self
        cancelButton.action = #selector(cancelAction)
        let stack = NSStackView(views: [statusLabel, cancelButton, finishButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 9
        stack.translatesAutoresizingMaskIntoConstraints = false
        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            statusLabel.widthAnchor.constraint(greaterThanOrEqualToConstant: 180)
        ])
    }

    private func configurePreviewPanel() {
        previewWindow.isOpaque = false
        previewWindow.backgroundColor = .clear
        previewWindow.hasShadow = true
        previewWindow.ignoresMouseEvents = true
        previewWindow.hidesOnDeactivate = false
        previewWindow.isReleasedWhenClosed = false
        previewWindow.level = .screenSaver
        previewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]

        let background = NSVisualEffectView(frame: previewWindow.contentView?.bounds ?? .zero)
        background.autoresizingMask = [.width, .height]
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        previewWindow.contentView = background

        let title = NSTextField(labelWithString: L.text("实时预览"))
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        previewStatusLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        previewStatusLabel.textColor = .secondaryLabelColor
        previewStatusLabel.alignment = .right
        let header = NSStackView(views: [title, previewStatusLabel])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.translatesAutoresizingMaskIntoConstraints = false

        previewScrollView.documentView = livePreviewView
        previewScrollView.hasVerticalScroller = true
        previewScrollView.autohidesScrollers = true
        previewScrollView.borderType = .noBorder
        previewScrollView.drawsBackground = true
        previewScrollView.backgroundColor = .windowBackgroundColor
        previewScrollView.translatesAutoresizingMaskIntoConstraints = false

        background.addSubview(header)
        background.addSubview(previewScrollView)
        NSLayoutConstraint.activate([
            header.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 10),
            header.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -10),
            header.topAnchor.constraint(equalTo: background.topAnchor, constant: 9),
            header.heightAnchor.constraint(equalToConstant: 20),
            previewScrollView.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 7),
            previewScrollView.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -7),
            previewScrollView.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 7),
            previewScrollView.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -7)
        ])
    }

    private func positionControlPanel() {
        let size = controlWindow.frame.size
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect
        let gap: CGFloat = 8
        var origin = CGPoint(
            x: min(selectionRect.maxX - size.width, visible.maxX - size.width - 8),
            y: selectionRect.minY - size.height - gap
        )
        if origin.y < visible.minY + 8 {
            origin.y = selectionRect.maxY + gap
        }
        origin.x = min(max(origin.x, visible.minX + 8), visible.maxX - size.width - 8)
        origin.y = min(max(origin.y, visible.minY + 8), visible.maxY - size.height - 8)
        controlWindow.setFrameOrigin(origin)
    }

    private func positionPreviewPanel() {
        let screen = NSScreen.screens.first { $0.frame.intersects(selectionRect) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? selectionRect
        let width: CGFloat = min(220, max(170, visible.width * 0.2))
        let height = min(max(240, selectionRect.height), min(620, visible.height - 16))
        previewWindow.setContentSize(CGSize(width: width, height: height))

        let gap: CGFloat = 8
        let rightX = selectionRect.maxX + gap
        let leftX = selectionRect.minX - width - gap
        let x: CGFloat
        if rightX + width <= visible.maxX - 8 {
            x = rightX
        } else if leftX >= visible.minX + 8 {
            x = leftX
        } else {
            x = min(max(selectionRect.maxX - width, visible.minX + 8), visible.maxX - width - 8)
        }
        let y = min(
            max(selectionRect.midY - height / 2, visible.minY + 8),
            visible.maxY - height - 8
        )
        previewWindow.setFrameOrigin(CGPoint(x: x, y: y))
    }

    private func receivedScroll(_ event: NSEvent) {
        receiveScroll(
            deltaX: event.scrollingDeltaX,
            deltaY: event.scrollingDeltaY,
            mouseLocation: NSEvent.mouseLocation
        )
    }

    func receiveScroll(deltaX: CGFloat, deltaY: CGFloat, mouseLocation: CGPoint) {
        guard !isFinished, selectionRect.contains(mouseLocation) else { return }
        let vertical = abs(deltaY)
        let horizontal = abs(deltaX)
        guard vertical > 0.05 || horizontal > 0.05 else { return }
        if horizontal > max(2, vertical * 1.5) {
            return
        }

        lastScrollEventAt = Date()
        if isCapturing {
            pendingCapture = true
            return
        }
        let elapsed = Date().timeIntervalSince(lastCaptureStartedAt)
        let delay = max(0.02, Self.minimumCaptureInterval - elapsed)
        scheduleCapture(after: delay)
    }

    private func scheduleCapture(after delay: TimeInterval) {
        guard captureTimer == nil else { return }
        let timer = Timer(
            timeInterval: delay,
            target: self,
            selector: #selector(captureAfterScroll),
            userInfo: nil,
            repeats: false
        )
        captureTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func captureAfterScroll() {
        captureTimer = nil
        guard !isFinished else { return }
        guard !isCapturing else {
            pendingCapture = true
            return
        }
        isCapturing = true
        lastCaptureStartedAt = Date()
        Task { [weak self] in
            guard let self else { return }
            do {
                let frame = try await captureFrame()
                let result = try stitcher.append(frame)
                isCapturing = false
                switch result {
                case .appended:
                    updateLivePreview()
                case .duplicate:
                    break
                }
                finishOrContinueAfterCapture()
            } catch LongCaptureStitchError.reverseScrollDetected {
                isCapturing = false
                finish()
            } catch LongCaptureStitchError.noReliableOverlap {
                isCapturing = false
                finishOrContinueAfterCapture()
            } catch LongCaptureStitchError.imageTooLarge {
                isCapturing = false
                finish()
            } catch {
                isCapturing = false
                cleanup()
                onError(error)
            }
        }
    }

    private func finishOrContinueAfterCapture() {
        if finishWhenIdle {
            finish()
        } else if pendingCapture
                    || Date().timeIntervalSince(lastScrollEventAt) < Self.scrollActivityTail {
            pendingCapture = false
            let elapsed = Date().timeIntervalSince(lastCaptureStartedAt)
            scheduleCapture(after: max(0.005, Self.minimumCaptureInterval - elapsed))
        }
    }

    private func updateInstruction() {
        statusLabel.attributedStringValue = Self.instructionAttributed
    }

    private func updateLivePreview() {
        previewWindow.contentView?.layoutSubtreeIfNeeded()
        let width = max(1, previewScrollView.contentSize.width)
        livePreviewView.update(
            images: stitcher.previewSegmentImages,
            sourcePixelWidth: stitcher.pixelWidth,
            displayWidth: width
        )
        let logicalHeight = Int((CGFloat(stitcher.pixelHeight) / max(1, pixelScale)).rounded())
        previewStatusLabel.stringValue = "\(logicalHeight) px"
        previewScrollView.layoutSubtreeIfNeeded()
        previewScrollView.contentView.scroll(
            to: CGPoint(
                x: 0,
                y: max(0, livePreviewView.frame.height - previewScrollView.contentSize.height)
            )
        )
        previewScrollView.reflectScrolledClipView(previewScrollView.contentView)
    }

    @objc private func finishAction() {
        finish()
    }

    private func finish() {
        guard !isFinished else { return }
        if isCapturing {
            finishWhenIdle = true
            finishButton.isEnabled = false
            return
        }
        do {
            let image = try stitcher.renderedImage()
            cleanup()
            onFinish(image, selectionRect.width)
        } catch {
            cleanup()
            onError(error)
        }
    }

    @objc private func cancelAction() {
        cancel()
    }

    func cancel() {
        guard !isFinished else { return }
        cleanup()
        onCancel()
    }

    private func cleanup() {
        guard !isFinished else { return }
        isFinished = true
        captureTimer?.invalidate()
        captureTimer = nil
        if let globalScrollMonitor {
            NSEvent.removeMonitor(globalScrollMonitor)
            self.globalScrollMonitor = nil
        }
        borderWindow.orderOut(nil)
        controlWindow.orderOut(nil)
        previewWindow.orderOut(nil)
        borderWindow.close()
        controlWindow.close()
        previewWindow.close()
    }
}

private final class LongCapturePreviewImageView: NSView {
    var image: CGImage {
        didSet { needsDisplay = true }
    }

    init(image: CGImage, frame: CGRect) {
        self.image = image
        super.init(frame: frame)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        NSGraphicsContext.current?.imageInterpolation = .high
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds)
    }
}

@MainActor
final class LongCapturePreviewWindowController: NSWindowController, NSWindowDelegate {
    private let originalImage: CGImage
    private var image: CGImage
    private let logicalWidth: CGFloat
    private let scrollView = NSScrollView()
    private let annotationCanvas: AnnotationCanvasView
    private let annotationToolbar: AnnotationToolbarView
    private var annotationToolbarHeightConstraint: NSLayoutConstraint?
    private let annotationToolbarExpandedHeight: CGFloat = 72
    private let dimensionLabel = NSTextField(labelWithString: "")
    private let annotateButton = NSButton(title: L.text("标注"), target: nil, action: nil)
    private let ocrButton = NSButton(title: L.text("OCR 文字识别"), target: nil, action: nil)
    private let onOCR: (CGImage, @escaping () -> Void) -> Void
    private let onDismiss: () -> Void
    private var isAnnotating = false
    private var watermarkCapturedAt = Date()
    private var sessionWatermarkEnabled = WatermarkPreferences.load().isEnabled
    private var activeTool: AnnotationTool = .select
    private var styles = Dictionary(uniqueKeysWithValues: AnnotationTool.drawingTools.map {
        ($0, AnnotationStylePreferences.load(for: $0))
    })
    private var didDismiss = false

    init(
        image: CGImage,
        logicalWidth: CGFloat,
        onOCR: @escaping (CGImage, @escaping () -> Void) -> Void,
        onDismiss: @escaping () -> Void
    ) {
        self.originalImage = image
        self.watermarkCapturedAt = Date()
        self.image = Self.previewImage(
            from: image,
            capturedAt: watermarkCapturedAt,
            isWatermarkEnabled: sessionWatermarkEnabled
        )
        self.logicalWidth = logicalWidth
        self.onOCR = onOCR
        self.onDismiss = onDismiss
        let displayWidth = min(760, max(320, logicalWidth))
        let displayHeight = displayWidth * CGFloat(self.image.height) / CGFloat(max(1, self.image.width))
        annotationCanvas = AnnotationCanvasView(
            frame: CGRect(x: 0, y: 0, width: displayWidth, height: displayHeight),
            baseImage: self.image
        )
        annotationToolbar = AnnotationToolbarView(
            frame: CGRect(x: 0, y: 0, width: 650, height: 72)
        )
        annotationToolbar.isHidden = true
        annotationToolbar.setLongCaptureEnabled(false)
        annotationToolbar.setGIFEnabled(false)
        annotationCanvas.setTool(
            .select,
            style: styles[.select] ?? .defaultStyle(for: .rectangle)
        )
        let visible = NSScreen.main?.visibleFrame.size ?? CGSize(width: 1200, height: 800)
        let window = NSWindow(
            contentRect: CGRect(
                x: 0,
                y: 0,
                width: min(820, visible.width - 80),
                height: min(760, visible.height - 100)
            ),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = L.text("长截图预览")
        window.minSize = CGSize(width: 520, height: 420)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        configureLayout()
        configureAnnotationActions()
        updateImageLayout()
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        dismissOnce()
    }

    func windowDidResize(_ notification: Notification) {
        updateImageLayout()
    }

    private static func previewImage(
        from image: CGImage,
        capturedAt: Date,
        isWatermarkEnabled: Bool
    ) -> CGImage {
        var configuration = WatermarkPreferences.load()
        configuration.isEnabled = true
        guard isWatermarkEnabled, configuration.hasRenderableContent else { return image }
        return (try? WatermarkRenderer.render(
            image: image,
            configuration: configuration,
            context: WatermarkContext(capturedAt: capturedAt)
        )) ?? image
    }

    private func configureLayout() {
        guard let content = window?.contentView else { return }
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder
        scrollView.documentView = annotationCanvas
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        dimensionLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        dimensionLabel.textColor = .secondaryLabelColor
        annotateButton.target = self
        annotateButton.action = #selector(annotateAction)
        ocrButton.target = self
        ocrButton.action = #selector(ocrAction)
        let copy = NSButton(title: L.text("复制"), target: self, action: #selector(copyAction))
        let save = NSButton(title: L.text("保存"), target: self, action: #selector(saveAction))
        save.keyEquivalent = "\r"
        let close = NSButton(title: L.text("关闭"), target: self, action: #selector(closeAction))
        let actions = NSStackView(views: [dimensionLabel, annotateButton, ocrButton, copy, save, close])
        actions.orientation = .horizontal
        actions.alignment = .centerY
        actions.spacing = 10
        actions.translatesAutoresizingMaskIntoConstraints = false
        dimensionLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        annotationToolbar.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(scrollView)
        content.addSubview(annotationToolbar)
        content.addSubview(actions)
        annotationToolbarHeightConstraint = annotationToolbar.heightAnchor.constraint(equalToConstant: 0)
        annotationToolbarHeightConstraint?.isActive = true
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
            scrollView.bottomAnchor.constraint(equalTo: annotationToolbar.topAnchor, constant: -8),
            annotationToolbar.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            annotationToolbar.widthAnchor.constraint(equalToConstant: 650),
            annotationToolbar.bottomAnchor.constraint(equalTo: actions.topAnchor, constant: -8),
            actions.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            actions.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            actions.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
            actions.heightAnchor.constraint(equalToConstant: 30)
        ])
    }

    private func updateImageLayout() {
        window?.contentView?.layoutSubtreeIfNeeded()
        let availableWidth = max(320, scrollView.contentSize.width)
        let displayWidth = min(max(logicalWidth, 320), availableWidth)
        let displayHeight = displayWidth * CGFloat(image.height) / CGFloat(max(1, image.width))
        annotationCanvas.setFrameSize(CGSize(width: displayWidth, height: displayHeight))
        annotationCanvas.needsDisplay = true
        dimensionLabel.stringValue = "\(image.width) × \(image.height) px"
    }

    private func configureAnnotationActions() {
        annotationToolbar.onToolSelected = { [weak self] tool in self?.setAnnotationTool(tool) }
        annotationToolbar.onStyleChanged = { [weak self] style in
            guard let self else { return }
            let target = self.annotationCanvas.document.selectedItem?.tool ?? self.activeTool
            guard target != .select else { return }
            self.styles[target] = style
            AnnotationStylePreferences.save(style, for: target)
            self.annotationCanvas.applyStyle(style)
        }
        annotationToolbar.onUndo = { [weak self] in self?.annotationCanvas.undo() }
        annotationToolbar.onRedo = { [weak self] in self?.annotationCanvas.redo() }
        annotationToolbar.onCancel = { [weak self] in self?.endAnnotationMode() }
        annotationToolbar.onCopy = { [weak self] in self?.copyAction() }
        annotationToolbar.onSave = { [weak self] in self?.saveAction() }
        annotationToolbar.onPin = { NSSound.beep() }
        annotationToolbar.onOCR = { [weak self] in self?.ocrAction() }
        annotationToolbar.onWatermarkToggle = { [weak self] enabled in
            self?.setSessionWatermarkEnabled(enabled)
        }
        annotationToolbar.setWatermarkState(
            hasContent: WatermarkPreferences.load().hasRenderableContent,
            enabled: sessionWatermarkEnabled
        )
        annotationToolbar.onWatermarkSetup = { [weak self] configuration in
            WatermarkPreferences.save(configuration)
            self?.setSessionWatermarkEnabled(true)
        }
        annotationCanvas.onDocumentChanged = { [weak self] in
            guard let self else { return }
            self.annotationToolbar.setUndoEnabled(
                self.annotationCanvas.document.undoManager.canUndo,
                redoEnabled: self.annotationCanvas.document.undoManager.canRedo
            )
        }
        annotationCanvas.onSelectionChanged = { [weak self] item in
            self?.annotationToolbar.setSelectedItem(item)
        }
        annotationCanvas.onToolShortcut = { [weak self] tool in self?.setAnnotationTool(tool) }
        annotationCanvas.onCancelCapture = { [weak self] in self?.endAnnotationMode() }
    }

    private func setAnnotationTool(_ tool: AnnotationTool) {
        activeTool = tool
        let style = styles[tool] ?? .defaultStyle(for: tool)
        annotationToolbar.setTool(tool, style: style)
        annotationCanvas.setTool(tool, style: style)
    }

    private func setSessionWatermarkEnabled(_ enabled: Bool) {
        sessionWatermarkEnabled = enabled
        image = Self.previewImage(
            from: originalImage,
            capturedAt: watermarkCapturedAt,
            isWatermarkEnabled: enabled
        )
        annotationCanvas.cancelPendingInteraction()
        annotationCanvas.updateCaptureArea(
            frame: annotationCanvas.frame,
            baseImage: image,
            logicalOrigin: annotationCanvas.bounds.origin
        )
        annotationCanvas.needsDisplay = true
        annotationToolbar.setWatermarkState(
            hasContent: WatermarkPreferences.load().hasRenderableContent,
            enabled: enabled
        )
    }

    @objc private func annotateAction() {
        if isAnnotating {
            endAnnotationMode()
        } else {
            beginAnnotationMode()
        }
    }

    private func beginAnnotationMode() {
        isAnnotating = true
        annotateButton.title = L.text("完成标注")
        annotationToolbar.isHidden = false
        annotationToolbarHeightConstraint?.constant = annotationToolbarExpandedHeight
        setAnnotationTool(activeTool)
        window?.contentView?.layoutSubtreeIfNeeded()
        window?.makeFirstResponder(annotationCanvas)
        updateImageLayout()
    }

    private func endAnnotationMode() {
        isAnnotating = false
        annotateButton.title = L.text("标注")
        annotationCanvas.cancelPendingInteraction()
        setAnnotationTool(.select)
        annotationToolbar.isHidden = true
        annotationToolbarHeightConstraint?.constant = 0
        window?.contentView?.layoutSubtreeIfNeeded()
        updateImageLayout()
    }

    @objc private func ocrAction() {
        guard ocrButton.isEnabled else { return }
        ocrButton.isEnabled = false
        ocrButton.title = L.text("正在识别…")
        onOCR(originalImage) { [weak self] in
            self?.ocrButton.isEnabled = true
            self?.ocrButton.title = L.text("OCR 文字识别")
        }
    }

    @objc private func copyAction() {
        do {
            try ScreenshotWriter.copyToPasteboard(outputImage())
            FeedbackSound.playCopyCompleted()
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func saveAction() {
        do {
            let url = try ScreenshotWriter.writeImage(outputImage())
            FeedbackSound.playSaveCompleted()
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            showError(error.localizedDescription)
        }
    }

    @objc private func closeAction() {
        close()
        dismissOnce()
    }

    private func dismissOnce() {
        guard !didDismiss else { return }
        didDismiss = true
        onDismiss()
    }

    private func outputImage() throws -> CGImage {
        try annotationCanvas.renderedImage()
    }

    private func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = L.text("长截图操作失败")
        alert.informativeText = message
        alert.runModal()
    }
}
